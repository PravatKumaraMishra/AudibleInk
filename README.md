<p align="center">
  <img src="Assets/AudibleInk.png" width="120" alt="AudibleInk icon">
</p>

# AudibleInk

A native macOS reader that turns Markdown and documents into local neural speech. Paste text or open Markdown, text, PDF, Word, and RTF files; follow the highlighted preview or listen from the floating player.

## Install

Requires an **Apple Silicon Mac with macOS 14 or later**.

1. Download the DMG from [GitHub Releases](https://github.com/PravatKumaraMishra/AudibleInk/releases/latest).
2. Open it and drag **AudibleInk** into **Applications**. A ZIP is also available.
3. Open AudibleInk. This release is ad-hoc signed, without Apple Developer ID or notarization. If macOS blocks opening it, attempt to launch once, then use **System Settings → Privacy & Security → Open Anyway** if you trust the download.

The release includes Python and its dependencies; no developer tools or project folder are needed. **Speech model weights are not bundled.** The selected model and voice download on first use, so start with an internet connection. After download, speech runs locally and document text stays on your Mac.

## Use

Paste text or choose **Open Document**, select a voice, then click **Start listening**. Click a preview passage to jump there. Code blocks are skipped unless enabled. Scanned PDFs need OCR before import.

Settings contains speech downloads, saved reference voices, pronunciation rules, audio caching, appearance, and editable shortcuts. The sidebar keeps recent documents and named drafts.

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

Add IndicF5 reference clips in Settings; use clean 5–10 second recordings and keep the original files available. IndicF5 and full Svara inference have not been verified for this release. IndicVoice-82M is no longer included. The English pronunciation tokenizer is included so it needs no separate setup.

Models are stored in `~/Library/Caches/MarkdownVoice/huggingface`. Delete downloads in Settings to reclaim space; the next use downloads them again.

Passage audio is cached in `~/Library/Caches/MarkdownVoice/audio` with a configurable limit. **Private audio** bypasses the persistent audio cache; drafts and preferences are still saved. Use **Clear Cache** to remove existing audio. The speech worker exits after a minute of stopped or paused inactivity and reloads when needed.

## Development

Install Apple's Command Line Tools and [uv](https://docs.astral.sh/uv/), then run:

```sh
./scripts/setup.sh
open build/AudibleInk.app
```

The development build uses the project's `.venv`; keep the project in place. Rebuild after editing Swift or Python:

```sh
./scripts/build.sh
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python scripts/check_shortcuts.py
.venv/bin/python scripts/check_drafts.py
.venv/bin/python scripts/check_cache_controls.py
.venv/bin/python scripts/check_idle.py
.venv/bin/python scripts/check_paused_idle.py --headless
```

To build the standalone ad-hoc-signed ZIP, DMG, and checksums:

```sh
./scripts/package_release.sh
```

Artifacts appear in `build/release/`. This downloads a portable Python runtime and installs `requirements.lock`; it does not download speech models. Runtime dependencies exclude PyTorch and the unused transformer pronunciation pipeline.

Third-party code, tokenizers, models, and voice assets retain their respective licenses. Main projects: [MLX Audio](https://github.com/Blaizzy/mlx-audio), [Misaki](https://github.com/hexgrad/misaki), [IndicF5-MLX](https://github.com/yogen-ghodke-113/indic-f5-mlx), and [markdown-it-py](https://github.com/executablebooks/markdown-it-py).
