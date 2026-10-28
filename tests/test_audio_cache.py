import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from worker import AudioCache, main


class AudioCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = AudioCache(self.root / 'cache')
        self.source = self.root / 'source.wav'
        with wave.open(str(self.source), 'wb') as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(24000)
            audio.writeframes(b'\x01\x00' * 2400)
        self.size = self.source.stat().st_size
        self.key = self.cache.key('Hello', 'af_heart', 1)

    def test_identity(self):
        self.assertEqual(self.key, self.cache.key('Hello', 'af_heart', 1.0))
        for text, voice, speed in [('hello', 'af_heart', 1), ('Hello', 'af_bella', 1), ('Hello', 'af_heart', 1.5)]:
            self.assertNotEqual(self.key, self.cache.key(text, voice, speed))

    def test_reuse_survives_playback_deletion_and_restart_without_age_limit(self):
        self.cache.store(self.key, self.source)
        cached = self.cache.directory / f'{self.key}.wav'
        old = time.time() - 30 * 86400
        os.utime(cached, (old, old))
        output = self.root / 'playback.wav'
        self.assertTrue(self.cache.copy_hit(self.key, output))
        self.assertEqual(output.read_bytes(), self.source.read_bytes())
        output.unlink()
        self.assertTrue(AudioCache(self.cache.directory).copy_hit(self.key, output))
        self.assertEqual(cached.stat().st_mtime, old, 'Prefetch must not count as playback')

    def test_size_limit_evicts_least_recently_played(self):
        self.cache.configure(self.size * 2)
        self.cache.store('first', self.source)
        self.cache.store('second', self.source)
        first = self.cache.directory / 'first.wav'
        second = self.cache.directory / 'second.wav'
        os.utime(first, (100, 100))
        os.utime(second, (200, 200))
        # First was replayed after second; the next store must evict second.
        os.utime(first, None)
        self.cache.store('third', self.source)
        self.assertTrue(first.exists())
        self.assertFalse(second.exists())
        self.assertTrue((self.cache.directory / 'third.wav').exists())
        self.assertEqual(self.cache.info()['cache_bytes'], self.size * 2)

    def test_lowering_limit_applies_immediately(self):
        self.cache.store('first', self.source)
        self.cache.store('second', self.source)
        self.cache.configure(self.size)
        self.assertEqual(self.cache.info()['cache_files'], 1)
        self.cache.configure(0)
        self.assertEqual(self.cache.info()['cache_bytes'], 0)
        self.cache.store(self.key, self.source)
        self.assertFalse(self.cache.copy_hit(self.key, self.root / 'output.wav'))

    def test_oversized_passage_does_not_displace_cache(self):
        self.cache.configure(self.size)
        self.cache.store('first', self.source)
        large = self.root / 'large.wav'
        large.write_bytes(self.source.read_bytes() * 2)
        self.cache.store('large', large)
        self.assertEqual(self.cache.info()['cache_files'], 1)
        self.assertTrue((self.cache.directory / 'first.wav').exists())

    def test_clear_only_removes_audio(self):
        self.cache.store(self.key, self.source)
        other = self.cache.directory / 'keep.txt'
        other.write_text('unrelated')
        self.cache.clear()
        self.assertTrue(other.exists())
        self.assertEqual(self.cache.info()['cache_bytes'], 0)
        self.assertEqual(self.cache.info()['cache_files'], 0)

    def test_same_configuration_does_not_scan(self):
        self.cache.configure(self.size)
        with patch.object(Path, 'glob', side_effect=AssertionError('Unexpected scan')):
            self.cache.configure(self.size)
            self.cache.info()

    def test_invalid_limit_is_rejected(self):
        for value in [-1, True, '100', 0.5]:
            with self.assertRaises(ValueError):
                self.cache.configure(value)

    def test_corrupt_cache_is_miss(self):
        path = self.cache.directory / f'{self.key}.wav'
        path.write_bytes(b'broken')
        self.cache.scan()
        self.assertFalse(self.cache.copy_hit(self.key, self.root / 'output.wav'))
        self.assertFalse(path.exists())
        self.assertEqual(self.cache.info()['cache_files'], 0)

    def run_requests(self, requests):
        import numpy as np
        calls = []

        def generate(text, **settings):
            calls.append(text)
            return [types.SimpleNamespace(audio=np.ones(2400) * 0.1, sample_rate=24000)]

        core = types.ModuleType('mlx.core')
        core.clear_cache = lambda: None
        mlx = types.ModuleType('mlx')
        mlx.core = core
        utils = types.ModuleType('mlx_audio.tts.utils')
        utils.load_model = lambda name: types.SimpleNamespace(generate=generate)
        protocol = ''.join(json.dumps(dict(id=str(i), **r)) + '\n' for i, r in enumerate(requests))
        output = io.StringIO()
        with patch.dict(os.environ, AUDIBLEINK_AUDIO_CACHE=str(self.cache.directory)):
            with patch.dict(sys.modules, {'mlx': mlx, 'mlx.core': core, 'mlx_audio.tts.utils': utils}):
                with patch('sys.stdin', io.StringIO(protocol)), patch('sys.stdout', output), patch('sys.__stdout__', output):
                    main()
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(responses), len(requests))
        self.assertTrue(all('error' not in response for response in responses), responses)
        return responses, calls

    def synth(self, text='Hello', **settings):
        return dict(command='synth', text=text, voice='af_heart', speed=1, **settings)

    def test_sequential_passages_reuse_cache_with_model_already_loaded(self):
        passages = ['First passage.', 'First passage.', 'Next passage.', 'First passage.']
        responses, calls = self.run_requests([self.synth(text) for text in passages])
        self.assertEqual([r['cache_hit'] for r in responses], [False, True, False, True])
        self.assertEqual(calls, ['First passage.', 'Next passage.'])

    def test_private_audio_bypasses_reads_and_writes(self):
        self.cache.store(self.key, self.source)
        before = (self.cache.directory / f'{self.key}.wav').read_bytes()
        responses, calls = self.run_requests([self.synth(private=True), self.synth('Private words', private=True)])
        self.assertEqual(calls, ['Hello', 'Private words'])
        self.assertTrue(all(not r['cache_hit'] and 'cache_key' not in r for r in responses))
        self.assertEqual(list(self.cache.directory.glob('*.wav')), [self.cache.directory / f'{self.key}.wav'])
        self.assertEqual((self.cache.directory / f'{self.key}.wav').read_bytes(), before)

    def test_clear_after_synthesis_and_size_settings_protocol(self):
        responses, calls = self.run_requests([self.synth(), dict(command='cache_clear'),
            self.synth(), dict(command='cache_info', cache_limit_bytes=0), self.synth()])
        self.assertEqual(calls, ['Hello', 'Hello', 'Hello'])
        self.assertEqual(responses[1]['cache_files'], 0)
        self.assertEqual(responses[3]['cache_bytes'], 0)
        self.assertEqual(responses[4]['cache_bytes'], 0)

    def test_switching_neural_engines_keeps_audio_cache_separate(self):
        requests = [self.synth(), dict(command='synth', text='Hello', voice='default', engine='soprano', speed=1), self.synth()]
        responses, calls = self.run_requests(requests)
        self.assertEqual(calls, ['Hello', 'Hello'])
        self.assertEqual([r['cache_hit'] for r in responses], [False, False, True])
        self.assertNotEqual(responses[0]['cache_key'], responses[1]['cache_key'])

    def test_delete_model_preserves_unrelated_repositories_and_audio(self):
        hub = self.root / 'huggingface' / 'hub'
        repositories = ['models--mlx-community--Kokoro-82M-bf16',
                        'models--hexgrad--Kokoro-82M', 'models--prince-canuma--Kokoro-82M']
        for name in repositories + ['models--unrelated--keep']:
            (hub / name).mkdir(parents=True)
            (hub / name / 'weights').write_text('fixture')
        self.cache.store(self.key, self.source)
        with patch.dict(os.environ, HF_HOME=str(hub.parent)):
            self.run_requests([dict(command='delete_model')])
        for name in repositories:
            self.assertFalse((hub / name).exists())
        self.assertTrue((hub / 'models--unrelated--keep' / 'weights').exists())
        self.assertTrue((self.cache.directory / f'{self.key}.wav').exists())

    def test_delete_voice_keeps_model_and_other_voices(self):
        hub = self.root / 'huggingface' / 'hub'
        repository = hub / 'models--prince-canuma--Kokoro-82M'
        voices = repository / 'snapshots' / 'revision' / 'voices'
        voices.mkdir(parents=True)
        blobs = repository / 'blobs'
        blobs.mkdir()
        (blobs / 'heart').write_bytes(b'voice')
        (voices / 'af_heart.safetensors').symlink_to(blobs / 'heart')
        (voices / 'af_bella.safetensors').write_bytes(b'keep')
        (repository / 'weights').write_bytes(b'keep')
        with patch.dict(os.environ, HF_HOME=str(hub.parent)):
            self.run_requests([dict(command='delete_voice', engine='kokoro', voice='af_heart')])
        self.assertFalse((blobs / 'heart').exists())
        self.assertFalse((voices / 'af_heart.safetensors').exists())
        self.assertTrue((voices / 'af_bella.safetensors').exists())
        self.assertTrue((repository / 'weights').exists())

    def test_svara_voice_and_cache_routing(self):
        request = dict(command='synth', text='নমস্কার', voice='Bengali (Female)', engine='svara', speed=1)
        responses, calls = self.run_requests([request, request])
        self.assertEqual([r['cache_hit'] for r in responses], [False, True])
        self.assertEqual(calls, ['নমস্কার'])
        self.assertNotEqual(self.cache.key('Hello', 'default', 1, 'svara'), self.cache.key('Hello', 'default', 1))

    def test_worker_hit_does_not_import_model(self):
        self.cache.store(self.key, self.source)
        (self.root / 'mlx.py').write_text("raise RuntimeError('Model must not load on cache hit')\n")
        env = dict(os.environ, AUDIBLEINK_AUDIO_CACHE=str(self.cache.directory), PYTHONPATH=str(self.root))
        result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / 'backend/worker.py')],
            input=json.dumps(dict(id='replay', **self.synth())) + '\n', capture_output=True, text=True, env=env, check=True)
        response = json.loads(result.stdout)
        self.assertNotIn('error', response, result.stderr)
        self.assertTrue(response['cache_hit'])
        self.assertEqual(response['cache_key'], self.key)


if __name__ == '__main__':
    unittest.main()
