"""Local JSON-lines worker. stdout is exclusively protocol; diagnostics use stderr."""
import contextlib
import json
import hashlib
import shutil
import wave
import os
from pathlib import Path
import re
import sys
import tempfile
import traceback

MODEL = 'mlx-community/Kokoro-82M-bf16'
VOICES = {'af_heart', 'af_bella', 'am_adam', 'am_michael', 'bf_emma', 'bm_george'}


from document import prepare_document, pronunciation_text


def markdown_chunks(source, include_code=False, limit=360):
    return prepare_document(source, include_code, limit)['chunks']


# Bump this when the model assets or synthesis implementation change.
AUDIO_CACHE_VERSION = 1
DEFAULT_CACHE_BYTES = 1024 * 1024 * 1024


class AudioCache:
    def __init__(self, directory=None, max_bytes=DEFAULT_CACHE_BYTES):
        self.directory = Path(directory or os.environ.get('MURMUR_AUDIO_CACHE',
            str(Path.home() / 'Library/Caches/MarkdownVoice/audio')))
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.max_bytes = max_bytes
        self.entries = None

    def key(self, text, voice, speed, engine='kokoro'):
        settings = [AUDIO_CACHE_VERSION, MODEL, engine, voice, float(speed), text]
        return hashlib.sha256(json.dumps(settings, ensure_ascii=False,
            separators=(',', ':')).encode('utf-8')).hexdigest()

    def scan(self):
        self.entries = {}
        for path in self.directory.glob('*.wav'):
            try:
                stat = path.stat()
                self.entries[path] = (stat.st_size, stat.st_mtime)
            except FileNotFoundError:
                pass

    def info(self):
        if self.entries is None:
            self.scan()
        return {'cache_bytes': sum(size for size, _ in self.entries.values()),
                'cache_files': len(self.entries), 'cache_limit_bytes': self.max_bytes}

    def configure(self, max_bytes):
        if isinstance(max_bytes, bool) or not isinstance(max_bytes, int) or max_bytes < 0:
            raise ValueError('Cache size must be a nonnegative integer')
        changed = self.max_bytes != max_bytes
        self.max_bytes = max_bytes
        if changed or self.entries is None:
            self.prune()

    def prune(self):
        # Only scan when configuring, adding audio, or explicitly refreshing usage.
        # Playback updates modification times, providing least-recently-played order.
        self.scan()
        total = self.info()['cache_bytes']
        if total <= self.max_bytes:
            return
        for path, (size, _) in sorted(self.entries.items(), key=lambda item: (item[1][1], item[0].name)):
            if total <= self.max_bytes:
                break
            path.unlink(missing_ok=True)
            total -= size
            del self.entries[path]

    def clear(self):
        for path in self.directory.glob('*.wav'):
            path.unlink(missing_ok=True)
        self.scan()

    def copy_hit(self, key, destination):
        path = self.directory / f'{key}.wav'
        if self.max_bytes == 0:
            return False
        try:
            # Ignore incomplete/corrupt files rather than handing them to playback.
            with wave.open(str(path), 'rb') as audio:
                if audio.getnframes() <= 0:
                    raise ValueError('Empty cached audio')
                expected = audio.getnframes() * audio.getnchannels() * audio.getsampwidth()
                if len(audio.readframes(audio.getnframes())) != expected:
                    raise ValueError('Truncated cached audio')
            shutil.copyfile(path, destination)
            return True
        except FileNotFoundError:
            if self.entries is not None:
                self.entries.pop(path, None)
            return False
        except (wave.Error, EOFError, ValueError):
            path.unlink(missing_ok=True)
            if self.entries is not None:
                self.entries.pop(path, None)
            return False

    def store(self, key, source):
        if self.max_bytes == 0 or Path(source).stat().st_size > self.max_bytes:
            return
        # Publish only complete WAVs. Playback always owns a separate temporary copy.
        descriptor, staging = tempfile.mkstemp(prefix='.audio-', dir=self.directory)
        try:
            with os.fdopen(descriptor, 'wb') as output, open(source, 'rb') as audio:
                shutil.copyfileobj(audio, output)
            os.replace(staging, self.directory / f'{key}.wav')
            self.prune()
        finally:
            Path(staging).unlink(missing_ok=True)


def main():
    model = None
    cache = AudioCache()
    with tempfile.TemporaryDirectory(prefix='markdown-voice-') as temp:
        for line in sys.stdin:
            try:
                request = json.loads(line)
                rid = request['id']
                cache.configure(request.get('cache_limit_bytes', cache.max_bytes))
                with contextlib.redirect_stdout(sys.stderr):
                    if request['command'] == 'cache_info':
                        cache.scan()
                        result = {}
                    elif request['command'] == 'cache_clear':
                        cache.clear()
                        result = {}
                    elif request['command'] == 'prepare':
                        result = prepare_document(request['text'], request.get('include_code', False))
                        result['speech_chunks'] = [pronunciation_text(c, request.get('pronunciations', ''), request.get('technical', True)) for c in result['chunks']]
                    elif request['command'] == 'synth':
                        engine = request.get('engine', 'kokoro')
                        if engine != 'kokoro':
                            raise ValueError('Unknown engine')
                        if request['voice'] not in VOICES:
                            raise ValueError('Unknown voice')
                        speed = float(request['speed'])
                        if not 0.5 <= speed <= 2:
                            raise ValueError('Speed must be between 0.5 and 2')
                        key = cache.key(request['text'], request['voice'], speed, engine)
                        # Do this before importing/loading the neural model.
                        path = str(Path(temp) / f'{os.urandom(16).hex()}.wav')
                        private = request.get('private', False)
                        if not private and cache.copy_hit(key, path):
                            print(json.dumps({'id': rid, 'path': path, 'cache_hit': True,
                                              'cache_key': key, **cache.info()}), file=sys.__stdout__, flush=True)
                            continue
                        import numpy as np
                        import soundfile as sf
                        if model is None:
                            import gc
                            import mlx.core as mx
                            from mlx_audio.tts.utils import load_model
                            model = None
                            gc.collect()
                            mx.clear_cache()
                            model = load_model(MODEL)
                        audio = []
                        sample_rate = 24000
                        results = model.generate(request['text'], voice=request['voice'], speed=speed, lang_code=request['voice'][0])
                        for part in results:
                            audio.append(np.asarray(part.audio).reshape(-1))
                            sample_rate = part.sample_rate
                        if not audio:
                            raise RuntimeError('The model returned no speech')
                        sf.write(path, np.concatenate(audio), sample_rate)
                        if not private:
                            cache.store(key, path)
                        result = {'path': path, 'cache_hit': False}
                        if not private:
                            result['cache_key'] = key
                        del audio, part, results
                    else:
                        raise ValueError('Unknown command')
                print(json.dumps({'id': rid, **result, **cache.info()}), flush=True)
            except Exception as exc:
                traceback.print_exc(file=sys.stderr)
                print(json.dumps({'id': request.get('id', '') if 'request' in locals() else '', 'error': str(exc)}), flush=True)


if __name__ == '__main__':
    main()
