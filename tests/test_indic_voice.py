"""Model inventory and reference voices need no model download or GPU."""
from pathlib import Path
import os
import sys
import tempfile
import unittest
import scipy.signal  # Load compiled modules outside temporary sys.modules patches.
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from worker import MODELS, model_storage, reference_identity, prepare_reference


class ModelStorageTests(unittest.TestCase):
    def test_only_present_models_count_physical_files_once(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, HF_HUB_CACHE=directory):
            self.assertNotIn('indicvoice', MODELS)
            self.assertEqual(model_storage(), {})
            repo = Path(directory) / 'models--ai4bharat--IndicF5'
            (repo / 'blobs').mkdir(parents=True)
            blob = repo / 'blobs/weight'
            blob.write_bytes(b'12345')
            (repo / 'snapshots').mkdir()
            (repo / 'snapshots/model.safetensors').symlink_to(blob)
            self.assertEqual(model_storage(), {'indicf5': 5})

    def test_reference_cache_identity_changes_with_clip_and_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            clip = Path(directory) / 'voice.wav'
            clip.write_bytes(b'first clip')
            request = {'reference_audio': str(clip), 'reference_text': 'Hello'}
            first = reference_identity(request)
            request['reference_text'] = 'Different words'
            self.assertNotEqual(first, reference_identity(request))
            request['reference_text'] = 'Hello'
            clip.write_bytes(b'new clip')
            self.assertNotEqual(first, reference_identity(request))
            clip.unlink()
            with self.assertRaisesRegex(ValueError, 'reference audio'):
                reference_identity(request)

    def test_reference_is_converted_to_mono_24khz(self):
        import numpy as np
        import soundfile as sf
        with tempfile.TemporaryDirectory() as directory:
            source, destination = Path(directory) / 'in.wav', Path(directory) / 'out.wav'
            wave = np.sin(np.arange(4410) * 2 * np.pi * 440 / 44100) * .3
            sf.write(source, np.column_stack([wave, wave]), 44100)
            prepare_reference(source, destination)
            samples, rate = sf.read(destination)
            self.assertEqual(rate, 24000)
            self.assertEqual(samples.shape, (2400,))
            self.assertGreater(np.max(np.abs(samples)), .2)

    def test_indicf5_protocol_routes_reference_and_reuses_audio(self):
        import io
        import json
        import types
        import numpy as np
        import soundfile as sf
        from worker import main
        with tempfile.TemporaryDirectory() as directory:
            reference = Path(directory) / 'speaker.wav'
            sf.write(reference, np.sin(np.arange(2400) * .1) * .2, 24000)
            calls = []
            def generate(model, **kwargs):
                calls.append(kwargs)
                self.assertEqual(sf.info(kwargs['ref_audio_path']).samplerate, 24000)
                return np.ones(2400) * .1
            core = types.ModuleType('mlx.core')
            core.clear_cache = lambda: None
            mlx = types.ModuleType('mlx')
            mlx.core = core
            backend = types.SimpleNamespace(load_indicf5=lambda: (object(), object()), generate=generate)
            request = dict(command='synth', engine='indicf5', voice='speaker', speed=1,
                           text='नमस्ते', reference_audio=str(reference), reference_text='नमस्ते')
            protocol = ''.join(json.dumps(dict(request, id=str(i))) + '\n' for i in range(2))
            output = io.StringIO()
            with patch.dict(os.environ, AUDIBLEINK_AUDIO_CACHE=str(Path(directory) / 'cache')):
                with patch.dict(sys.modules, {'mlx': mlx, 'mlx.core': core, 'indic_f5_mlx': backend}):
                    with patch('sys.stdin', io.StringIO(protocol)), patch('sys.stdout', output), patch('sys.__stdout__', output):
                        main()
            responses = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertTrue(all('error' not in r for r in responses), responses)
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0]['ref_text'], 'नमस्ते')
            self.assertEqual([r['cache_hit'] for r in responses], [False, True])
