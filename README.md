<p align="center">
  <img src="Assets/Murmur.png" width="160" alt="Murmur waveform app icon">
</p>

# Murmur

I built Murmur to listen to Markdown notes on my Mac. I can paste a document, open a `.md` file, and follow along in a rendered preview while speech is generated locally. The interface is native SwiftUI; the neural speech models run in a Python worker through MLX.

## Getting started

I use an Apple Silicon Mac, macOS 14 or later, Apple's Command Line Tools, and [uv](https://docs.astral.sh/uv/). The setup script creates a Python 3.11 environment, installs the speech and Markdown dependencies, and builds the app.

```sh
# Install Apple's Command Line Tools if needed.
xcode-select --install

# Install uv if needed, using Homebrew.
brew install uv

# From the project directory:
./scripts/setup.sh
open build/Murmur.app
```

The app is built and signed locally. It references `.venv` in this project, so I keep the project folder in place. If I move it, I run `./scripts/build.sh` again. This build is not a standalone, notarized installer.

## Reading a document

1. Paste Markdown into **Write**, or use **Open Markdown** / Command-O to import a UTF-8 file.
2. Choose a voice and set the pace. **Ryan · Qwen3 0.6B · 8-bit** is the default.
3. Click **Start listening**, press Command-Return, or click a passage in **Preview**.
4. Use Pause, Resume, and Stop to control playback. I stop reading before editing the source.

Preview renders headings, nested lists, emphasis, tables, quotes, and fenced code. A pale green highlight follows the current speech passage. **Follow reading** scrolls to that passage; scrolling manually turns Follow off so I can browse elsewhere.

To jump ahead, I click another passage or select text and choose **Read from selection**. Reading starts at the beginning of the containing speech passage and continues through the document. Highlighting follows passages rather than individual words.

Code blocks stay visible in Preview but are skipped during speech unless **Read code blocks** is enabled. Link labels, image alt text, inline code, and table cells are read aloud. Link destinations, raw HTML, and YAML front matter are skipped. Remote images and embedded HTML are not loaded in Preview.

My current draft and pronunciation dictionary are saved in the app's local macOS preferences. Voice, pace, dictionary, and code settings apply to the next reading.

## Local speech engines

| Engine | Model / source | Voices in Murmur |
| --- | --- | --- |
| Qwen3-TTS | `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit` | Ryan, Aiden, Vivian |
| Kokoro | `mlx-community/Kokoro-82M-bf16` | Heart, Bella, Michael, Emma, George |
| macOS speech | Installed English (India) voices | Rishi, plus Aman or Tara when macOS exposes them |

I use Qwen's 0.6B 8-bit model to try a larger neural engine on an M1 Air. Kokoro is the smaller alternative. Neither model's presets in this app are dedicated Indian English voices; I use the installed macOS voices for that accent.

The worker loads models on demand and keeps one neural engine resident at a time. Switching from Qwen to Kokoro, or back, releases the previous neural model. It generates short passages and buffers at most one future passage. Playback can wait between passages if generation falls behind. Stopping cancels playback immediately; an in-flight calculation can still finish before the next request is handled. Quitting terminates the worker.

Kokoro applies pace during synthesis. Qwen applies pace through the native audio player's playback rate. Actual latency and memory use depend on the machine, available memory, and document content; I have not established an M1 Air performance benchmark.

The first use downloads model files from Hugging Face into:

```text
~/Library/Caches/MarkdownVoice/huggingface
```

After the required model and voice assets are cached, inference runs locally. Document text is not uploaded. I try the voices I need before going offline. Temporary neural WAV files are removed after loading, stopping, or worker exit.

## Technical pronunciation

I use **Pronunciation dictionary…** to control acronyms, framework names, and unfamiliar phrases without changing the displayed document. Each line defines a whole-term, case-sensitive replacement:

```text
API = A P I
JSON = jay son
JPA = J P A
SQL = sequel
@GetMapping = get mapping
```

I can change `SQL = sequel` to `SQL = S Q L`, or add a phonetic spelling for a name. The optional technical cleanup separates camelCase words and reads common operators aloud. These rules work with both neural engines and macOS speech. A larger model can still mispronounce technical vocabulary, so I keep the dictionary available for either engine.

## Development

```sh
# Rebuild after editing Swift or Python sources.
./scripts/build.sh

# Run Markdown, rendering, alignment, and pronunciation tests.
.venv/bin/python -m unittest discover -s tests -v

# Exercise real speech generation and write a sample WAV.
.venv/bin/python scripts/check_neural.py
.venv/bin/python scripts/check_neural.py --qwen

# Check the app's local signature.
codesign --verify --deep --strict build/Murmur.app
```

The speech checks write `build/kokoro-sample.wav` and `build/qwen-sample.wav`. They verify that generated audio is nonempty and non-silent. Both engines have also been exercised through the desktop app with Preview highlighting. The test suite covers Markdown cleanup, rendered structure, speech anchors across formatting, unsafe HTML, and pronunciation replacements.

`requirements.txt` pins the direct dependencies and compatible tokenizer helpers. `requirements.lock` records the full installed Python environment. For a complete dependency reproduction, I can install the lock file into a Python 3.11 environment with `uv pip install --python .venv/bin/python -r requirements.lock`.

### App icon

I use the dark green waveform mark for the desktop icon, with the Murmur name shown by macOS beneath it. The icon is drawn with AppKit at each macOS icon size. To regenerate it:

```sh
mkdir -p .cache/clang
swift -module-cache-path .cache/clang scripts/generate_icon.swift Assets
iconutil -c icns Assets/Murmur.iconset -o Assets/Murmur.icns
./scripts/build.sh
```

I keep the generator, PNG preview, and `.icns` asset in Git. The intermediate `.iconset` directory is generated and ignored.

### Project layout

```text
Assets/                      App icon and README preview
Sources/MarkdownVoice.swift  SwiftUI interface, playback, and worker lifecycle
Sources/MarkdownPreview.swift Local Markdown preview and reading navigation
backend/document.py          Markdown rendering, speech anchors, pronunciation
backend/worker.py            JSON-lines worker for Kokoro and Qwen
scripts/                     Setup, build, icon generation, and speech checks
tests/                       Markdown and pronunciation regression tests
```

### Working with Git

```sh
git status
git log --oneline

# Stage only the files relevant to a change, then describe that change.
git add path/to/changed-file
git commit -m "Describe the change"
```

I keep virtual environments, model caches, generated app bundles, audio samples, and recovered reading drafts out of Git. The repository contains source, dependencies, tests, assets, and setup instructions.

## Dependencies and model licenses

Murmur uses [MLX Audio](https://github.com/Blaizzy/mlx-audio), [Qwen3-TTS 8-bit weights](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit), [Kokoro weights](https://huggingface.co/mlx-community/Kokoro-82M-bf16), [Misaki](https://github.com/hexgrad/misaki), and [markdown-it-py](https://github.com/executablebooks/markdown-it-py). Their code, models, and voice assets retain their respective licenses.
