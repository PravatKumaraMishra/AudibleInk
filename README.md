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

1. Paste Markdown into **Input**, or use **Open Markdown** / Command-O to import a UTF-8 file.
2. Choose a voice and set the pace. **Heart · American · Kokoro** is the default.
3. Click **Start listening**, press Command-Return, or click a passage in **Preview**.
4. Use Pause, Resume, and Stop to control playback. I stop reading before editing the source.

Preview renders headings, nested lists, emphasis, tables, quotes, and fenced code. A pale green highlight follows the current speech passage. **Follow reading** scrolls to that passage; scrolling manually turns Follow off so I can browse elsewhere.

To jump ahead, I click another passage or select text and choose **Read from selection**. Reading starts at the beginning of the containing speech passage and continues through the document. Highlighting follows passages rather than individual words.

Code blocks stay visible in Preview but are skipped during speech unless **Read code blocks** is enabled. Link labels, image alt text, inline code, and table cells are read aloud. Link destinations, raw HTML, and YAML front matter are skipped. Remote images and embedded HTML are not loaded in Preview.

My current draft and pronunciation dictionary are saved in the app's local macOS preferences. Voice, model, dictionary, and code settings apply to the next reading. Pace changes apply immediately. The model choice is saved between launches.

## Local speech engines

| Engine | Model / source | Voices in Murmur |
| --- | --- | --- |
| Kokoro | `mlx-community/Kokoro-82M-bf16` | Heart, Bella, Michael, Emma, George |

Kokoro is the local neural engine, with American Heart (`af_heart`) selected by default. Its [official voice catalogue](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md) lists American and British English voices and separate Hindi voices, but no dedicated Indian English voices. Murmur offers Kokoro voices only.

The worker loads Kokoro on demand and keeps it resident for subsequent passages. After one minute without reading or document preparation, Murmur terminates the worker to release its model, Python runtime, and GPU memory. Editing resets the idle countdown. Active and paused readings are preserved. Starting again reloads the worker and model, so the first passage takes longer. It generates short passages and buffers at most one future passage. Playback can wait between passages if generation falls behind. Stopping cancels playback immediately; an in-flight calculation can still finish before the next request is handled. Quitting terminates the worker.

Kokoro uses `mlx-community/Kokoro-82M-bf16`. The model downloads on first use.

The larger window and reduced margins give Input and Preview more room. Use **Expand document** in the document header to hide the sidebar; **Show voice controls** restores it. The window supports resizing and macOS full screen.

Kokoro generates at its normal pace; the audio player adjusts playback rate immediately, including buffered passages. Actual latency and memory use depend on the machine, available memory, and document content; I have not established an M1 Air performance benchmark.

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

I can change `SQL = sequel` to `SQL = S Q L`, or add a phonetic spelling for a name. The optional technical cleanup separates camelCase words and reads common operators aloud. These rules work with every Kokoro model. Neural speech can still mispronounce technical vocabulary, so I keep the dictionary available for each model.

## Development

```sh
# Rebuild after editing Swift or Python sources.
./scripts/build.sh

# Run Markdown, rendering, alignment, and pronunciation tests.
.venv/bin/python -m unittest discover -s tests -v

# Check idle release and restart with an accelerated timeout.
.venv/bin/python scripts/check_idle.py

# Exercise real speech generation and write a sample WAV.
.venv/bin/python scripts/check_neural.py

# Check the app's local signature.
codesign --verify --deep --strict build/Murmur.app
```

The speech check writes `build/kokoro-bf16-sample.wav` and verifies that generated audio is nonempty and non-silent. Kokoro also supports Preview highlighting in the desktop app. The test suite covers Markdown cleanup, rendered structure, speech anchors across formatting, unsafe HTML, and pronunciation replacements.

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
backend/worker.py            JSON-lines worker for Kokoro
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

Murmur uses [MLX Audio](https://github.com/Blaizzy/mlx-audio), [Kokoro weights](https://huggingface.co/mlx-community/Kokoro-82M-bf16), [Misaki](https://github.com/hexgrad/misaki), and [markdown-it-py](https://github.com/executablebooks/markdown-it-py). Their code, models, and voice assets retain their respective licenses.
