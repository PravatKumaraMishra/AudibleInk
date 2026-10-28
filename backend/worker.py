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
MODELS = {'kokoro': MODEL, 'soprano': 'mlx-community/Soprano-80M-bf16', 'svara': 'mlx-community/svara-tts-v1-4bit', 'indicf5': 'ai4bharat/IndicF5'}
VOICES = {'af_heart', 'af_bella', 'am_adam', 'am_michael', 'bf_emma', 'bm_george', 'hf_alpha', 'hm_omega'}


from document import prepare_document, pronunciation_text


def markdown_chunks(source, include_code=False, limit=360):
    return prepare_document(source, include_code, limit)['chunks']


# Bump this when the model assets or synthesis implementation change.
AUDIO_CACHE_VERSION = 1
DEFAULT_CACHE_BYTES = 1024 * 1024 * 1024


class AudioCache:
    def __init__(self, directory=None, max_bytes=DEFAULT_CACHE_BYTES):
        self.directory = Path(directory or os.environ.get('AUDIBLEINK_AUDIO_CACHE',
            str(Path.home() / 'Library/Caches/MarkdownVoice/audio')))
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.max_bytes = max_bytes
        self.entries = None

    def key(self, text, voice, speed, engine='kokoro'):
        settings = [AUDIO_CACHE_VERSION, MODELS[engine], engine, voice, float(speed), text]
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


def hub_directory():
    return Path(os.environ.get('HF_HUB_CACHE') or os.environ.get('HUGGINGFACE_HUB_CACHE') or str(Path(os.environ.get('HF_HOME', str(Path.home() / 'Library/Caches/MarkdownVoice/huggingface'))) / 'hub'))


def model_repositories(engine):
    if engine == 'kokoro':
        return ('models--mlx-community--Kokoro-82M-bf16', 'models--hexgrad--Kokoro-82M', 'models--prince-canuma--Kokoro-82M')
    if engine == 'indicf5':
        return ('models--ai4bharat--IndicF5', 'models--lucasnewman--vocos-mel-24khz')
    return ('models--' + MODELS[engine].replace('/', '--'),)


def model_storage():
    usage = {}
    for engine in MODELS:
        size = 0
        for repository in model_repositories(engine):
            directory = hub_directory() / repository
            if directory.is_symlink():
                continue
            for path in directory.rglob('*'):
                if path.is_file() and not path.is_symlink():
                    size += path.stat().st_size
        if size:
            usage[engine] = size
    return usage


def prepare_reference(source, destination):
    import math
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly
    samples, rate = sf.read(source, always_2d=True)
    if not len(samples):
        raise ValueError('The reference clip is empty')
    mono = samples.mean(axis=1)
    if rate != 24000:
        divisor = math.gcd(rate, 24000)
        mono = resample_poly(mono, 24000 // divisor, rate // divisor)
    if not np.isfinite(mono).all() or np.max(np.abs(mono)) < 1e-6:
        raise ValueError('The reference clip contains no usable audio')
    sf.write(destination, mono, 24000, subtype='PCM_16')
    return str(destination)


def reference_identity(request):
    path = Path(request.get('reference_audio', ''))
    transcript = request.get('reference_text', '').strip()
    if not path.is_file() or not transcript:
        raise ValueError('IndicF5 needs a reference audio clip and its exact transcript. Add a voice in Settings.')
    # Both clip contents and transcript affect synthesized audio.
    return hashlib.sha256(path.read_bytes() + transcript.encode('utf-8')).hexdigest()


def configure_espeak_data(temporary_directory):
    # eSpeak falls back to its build-machine path when the supplied path is too
    # long. Use a short, private copy for app bundles in deep folder hierarchies.
    import espeakng_loader
    from misaki.espeak import EspeakWrapper
    data = Path(espeakng_loader.get_data_path())
    if len(os.fsencode(data)) > 150:
        data = Path(temporary_directory) / 'espeak-ng-data'
        if not data.exists():
            shutil.copytree(espeakng_loader.get_data_path(), data)
    EspeakWrapper.set_data_path(str(data))


def main():
    model = None
    model_engine = None
    cache = AudioCache()
    with tempfile.TemporaryDirectory(prefix='markdown-voice-', dir='/tmp') as temp:
        for line in sys.stdin:
            try:
                request = json.loads(line)
                rid = request['id']
                cache.configure(request.get('cache_limit_bytes', cache.max_bytes))
                with contextlib.redirect_stdout(sys.stderr):
                    if request['command'] == 'model_info':
                        result = {'model_bytes': model_storage()}
                    elif request['command'] == 'cache_info':
                        cache.scan()
                        result = {}
                    elif request['command'] == 'cache_clear':
                        cache.clear()
                        result = {}
                    elif request['command'] == 'delete_voice':
                        if request.get('engine') != 'kokoro' or request.get('voice') not in VOICES:
                            raise ValueError('Unknown downloadable voice')
                        model = None
                        model_engine = None
                        import gc
                        gc.collect()
                        hub = Path(os.environ.get('HF_HUB_CACHE') or os.environ.get('HUGGINGFACE_HUB_CACHE') or str(Path(os.environ.get('HF_HOME', str(Path.home() / 'Library/Caches/MarkdownVoice/huggingface'))) / 'hub'))
                        removed = 0
                        for repository in ('models--mlx-community--Kokoro-82M-bf16', 'models--hexgrad--Kokoro-82M', 'models--prince-canuma--Kokoro-82M'):
                            directory = hub / repository
                            for extension in ('safetensors', 'pt'):
                                for voice_file in directory.glob(f"snapshots/*/voices/{request['voice']}.{extension}"):
                                    target = voice_file.resolve()
                                    if voice_file.is_symlink() and target.is_relative_to((directory / 'blobs').resolve()):
                                        target.unlink(missing_ok=True)
                                    voice_file.unlink(missing_ok=True)
                                    removed += 1
                        result = {'removed_voice_files': removed}
                    elif request['command'] == 'delete_model':
                        engine = request.get('engine', 'kokoro')
                        if engine not in MODELS:
                            raise ValueError('Unknown model')
                        model = None
                        model_engine = None
                        import gc
                        gc.collect()
                        # Delete only known Kokoro repositories, never the whole hub.
                        hub = Path(os.environ.get('HF_HUB_CACHE') or os.environ.get('HUGGINGFACE_HUB_CACHE') or str(Path(os.environ.get('HF_HOME', str(Path.home() / 'Library/Caches/MarkdownVoice/huggingface'))) / 'hub'))
                        repositories = model_repositories(engine)
                        for repository in repositories:
                            directory = hub / repository
                            if directory.is_symlink():
                                directory.unlink()
                            elif directory.exists():
                                shutil.rmtree(directory)
                        result = {}
                    elif request['command'] == 'prepare':
                        result = prepare_document(request['text'], request.get('include_code', False))
                        result['speech_chunks'] = [pronunciation_text(c, request.get('pronunciations', ''), request.get('technical', True)) for c in result['chunks']]
                    elif request['command'] == 'synth':
                        engine = request.get('engine', 'kokoro')
                        if engine not in tuple(MODELS):
                            raise ValueError('Unknown engine')
                        if engine == 'kokoro' and request['voice'] not in VOICES:
                            raise ValueError('Unknown voice')
                        if engine == 'svara' and request['voice'] not in {f'{language} ({gender})' for language in ('Hindi', 'Bengali', 'English (Indian)', 'Marathi', 'Telugu', 'Kannada', 'Tamil', 'Malayalam', 'Gujarati', 'Punjabi', 'Assamese', 'Bhojpuri', 'Magahi', 'Maithili', 'Chhattisgarhi', 'Bodo', 'Dogri', 'Nepali', 'Sanskrit') for gender in ('Female', 'Male')}:
                            raise ValueError('Unknown Svara voice')
                        speed = float(request['speed'])
                        if not 0.5 <= speed <= 2:
                            raise ValueError('Speed must be between 0.5 and 2')
                        voice_key = request['voice']
                        if engine == 'indicf5':
                            voice_key += reference_identity(request)
                        key = cache.key(request['text'], voice_key, speed, engine)
                        # Do this before importing/loading the neural model.
                        path = str(Path(temp) / f'{os.urandom(16).hex()}.wav')
                        private = request.get('private', False)
                        if not private and cache.copy_hit(key, path):
                            print(json.dumps({'id': rid, 'path': path, 'cache_hit': True,
                                              'cache_key': key, **cache.info()}), file=sys.__stdout__, flush=True)
                            continue
                        import numpy as np
                        import soundfile as sf
                        if model is None or model_engine != engine:
                            import gc
                            import mlx.core as mx
                            model = None
                            gc.collect()
                            mx.clear_cache()
                            if engine == 'kokoro':
                                configure_espeak_data(temp)
                            if engine == 'indicf5':
                                try:
                                    from indic_f5_mlx import load_indicf5
                                except ImportError as exc:
                                    raise RuntimeError('Install IndicF5-MLX with scripts/setup.sh, accept access at huggingface.co/ai4bharat/IndicF5, and run hf auth login.') from exc
                                try:
                                    model = load_indicf5()[0]
                                except Exception as exc:
                                    raise RuntimeError('IndicF5 could not load. Accept access at huggingface.co/ai4bharat/IndicF5 and run hf auth login using this project runtime. ' + str(exc)) from exc
                            else:
                                from mlx_audio.tts.utils import load_model
                                model = load_model(MODELS[engine])
                            model_engine = engine
                        audio = []
                        sample_rate = 24000
                        if engine == 'indicf5':
                            from indic_f5_mlx import generate
                            reference_path = prepare_reference(request['reference_audio'], Path(temp) / 'reference.wav')
                            samples = generate(model, ref_audio_path=reference_path, ref_text=request['reference_text'], text=request['text'], steps=16)
                            from types import SimpleNamespace
                            results = [SimpleNamespace(audio=samples, sample_rate=24000)]
                        elif engine == 'kokoro':
                            results = model.generate(request['text'], voice=request['voice'], speed=speed, lang_code=request['voice'][0])
                        elif engine == 'svara':
                            results = model.generate(request['text'], voice=request['voice'], temperature=0.75, top_p=0.9, top_k=40, repetition_penalty=1.1, max_tokens=2048)
                        else:
                            results = model.generate(request['text'])
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
