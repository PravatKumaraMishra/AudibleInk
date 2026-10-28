<p align="center">
  <img src="Assets/AudibleInk.png" width="120" alt="AudibleInk icon">
</p>

# AudibleInk

A native macOS reader that turns Markdown and documents into local neural speech. Paste text or open Markdown, text, PDF, Word, and RTF files; follow the highlighted preview or listen from the floating player.

## Install

Requires an **Apple Silicon Mac with macOS 14 or later**.

1. Download the DMG from [GitHub Releases](https://github.com/PravatKumaraMishra/AudibleInk/releases/latest).
2. Open it and drag **AudibleInk** into **Applications**. A ZIP is also available.
3. Open AudibleInk.

**If macOS blocks the app:** this release is ad-hoc signed, without Apple Developer ID or notarization. After attempting to open it, go to **System Settings → Privacy & Security**, find the message about AudibleInk, and click **Open Anyway**. Complete any confirmation macOS requests. Only allow the app if you trust the download.

Alternatively, [build the app yourself from source](#build-from-source) using the instructions below.

The installer includes Python and the small Markdown preview libraries. **Each speech engine installs its own dependencies and downloads its weights on first use.** Internet is required the first time you use each engine; no developer tools or project folder are needed. Later speech runs locally.

Release builds contain no personal documents, recent-file history, reference recordings, tokens, or cached audio. Your existing local drafts and settings stay on your Mac when upgrading.

## Use

Paste text or choose **Open Document**, select a voice, then click **Start listening**. Click a preview passage to jump there. Code blocks are skipped unless enabled. Scanned PDFs need OCR before import.

Settings contains speech downloads, saved reference voices, pronunciation rules, audio caching, appearance, and editable shortcuts. The sidebar keeps recent documents and named drafts. Hover over an entry and click **×** beside Rename to remove it; imported files stay on disk. Quit is beside Settings at the bottom of the sidebar, or below it when collapsed.

In **Settings → Updates**, use **Check for Updates** to check GitHub manually. **Check for updates at launch** is off by default; enable it to check at startup. An available update appears as a floating badge above Settings in either sidebar mode. Click it to open Updates, then download from GitHub.

| Shortcut | Action |
| --- | --- |
| Command-O | Open document |
| Space / Command-Return | Start, pause, or resume |
| S | Stop |
| Command-P | Switch Input / Preview |
| Command-T | Switch main window / floating player |
| Command-comma | Settings |

Single-key shortcuts apply outside text editing. Press Escape to leave the editor.

## Speech engines

| Engine | Voices / requirements |
| --- | --- |
| Kokoro | English and Hindi; Heart is the default English voice |
| Soprano 80M | English, one voice |
| Svara v1, 4-bit | Indian languages; about 2 GB plus its shared decoder |
| IndicF5-MLX | Indian languages using a reference recording and exact transcript; requires approved access to the gated [IndicF5 weights](https://huggingface.co/ai4bharat/IndicF5) and Hugging Face authentication |

Add IndicF5 reference clips in Settings; use clean 5–10 second recordings and keep the original files available. IndicF5 and full Svara inference have not been verified for this release. IndicVoice-82M is no longer included. The English pronunciation tokenizer installs automatically with Kokoro.

Engine libraries are stored in `~/Library/Application Support/AudibleInk/engines`. Failed setup can be retried by starting playback again. Deleting a model removes its weights and keeps its installed libraries.

Models are stored in `~/Library/Caches/MarkdownVoice/huggingface`. Delete downloads in Settings to reclaim space; the next use downloads them again.

Passage audio is cached in `~/Library/Caches/MarkdownVoice/audio` with a configurable limit. **Private audio** bypasses the persistent audio cache; drafts and preferences are still saved. Use **Clear Cache** to remove existing audio. The speech worker exits after a minute of stopped or paused inactivity and reloads when needed.

## Build from source

Install Apple's Command Line Tools and [uv](https://docs.astral.sh/uv/), then run:

```sh
git clone https://github.com/PravatKumaraMishra/AudibleInk.git
cd AudibleInk
./scripts/setup.sh
open build/AudibleInk.app
```

The development build uses the project's `.venv`; keep the project in place. Rebuild after editing Swift or Python:

```sh
./scripts/build.sh
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python scripts/check_shortcuts.py
.venv/bin/python scripts/check_drafts.py
.venv/bin/python scripts/check_updates.py
.venv/bin/python scripts/check_cache_controls.py
.venv/bin/python scripts/check_idle.py
.venv/bin/python scripts/check_paused_idle.py --headless
```

To build the standalone ad-hoc-signed ZIP, DMG, and checksums:

```sh
./scripts/package_release.sh
```

Artifacts appear in `build/release/`. This builds from a clean directory with a portable Python runtime and `backend/requirements/base.lock`. Per-engine locks are bundled for first-use installation; speech weights and engine libraries are excluded. Run `python3 scripts/check_release.py` to audit the bundle. Runtime dependencies exclude PyTorch and the unused transformer pronunciation pipeline.

Third-party code, tokenizers, models, and voice assets retain their respective licenses. Main projects: [MLX Audio](https://github.com/Blaizzy/mlx-audio), [Misaki](https://github.com/hexgrad/misaki), [IndicF5-MLX](https://github.com/yogen-ghodke-113/indic-f5-mlx), and [markdown-it-py](https://github.com/executablebooks/markdown-it-py).
