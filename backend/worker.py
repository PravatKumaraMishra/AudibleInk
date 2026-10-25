"""Local JSON-lines worker. stdout is exclusively protocol; diagnostics use stderr."""
import contextlib
import json
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


def main():
    model = None
    with tempfile.TemporaryDirectory(prefix='markdown-voice-') as temp:
        for line in sys.stdin:
            try:
                request = json.loads(line)
                rid = request['id']
                with contextlib.redirect_stdout(sys.stderr):
                    if request['command'] == 'prepare':
                        result = prepare_document(request['text'], request.get('include_code', False))
                        result['speech_chunks'] = [pronunciation_text(c, request.get('pronunciations', ''), request.get('technical', True)) for c in result['chunks']]
                    elif request['command'] == 'synth':
                        import numpy as np
                        import soundfile as sf
                        engine = request.get('engine', 'kokoro')
                        if engine != 'kokoro':
                            raise ValueError('Unknown engine')
                        if request['voice'] not in VOICES:
                            raise ValueError('Unknown voice')
                        speed = float(request['speed'])
                        if not 0.5 <= speed <= 2:
                            raise ValueError('Speed must be between 0.5 and 2')
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
                        path = str(Path(temp) / f'{rid}.wav')
                        sf.write(path, np.concatenate(audio), sample_rate)
                        result = {'path': path}
                        del audio, part, results
                    else:
                        raise ValueError('Unknown command')
                print(json.dumps({'id': rid, **result}), flush=True)
            except Exception as exc:
                traceback.print_exc(file=sys.stderr)
                print(json.dumps({'id': request.get('id', '') if 'request' in locals() else '', 'error': str(exc)}), flush=True)


if __name__ == '__main__':
    main()
