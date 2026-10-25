"""Check shortcut routing without sending keyboard events to the desktop."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/MarkdownVoice.swift').read_text().split('@main struct MarkdownVoiceApp:')[0]
harness = r'''
@main struct ShortcutCheck {
    static func main() {
        let commandKeys = ["s": "startStop", "i": "i", "[": "[", "]": "]", "p": "preview", "f": "follow", "\u{f702}": "previous", "\u{f703}": "next", "\r": " "]
        for (key, expected) in commandKeys {
            for editing in [true, false] {
                precondition(PlaybackShortcuts.command(for: key, modifiers: .command, editing: editing) == expected)
            }
        }
        for key in [" ", "s", "i", "[", "]"] {
            precondition(PlaybackShortcuts.command(for: key, modifiers: [], editing: false) == key)
            precondition(PlaybackShortcuts.command(for: key, modifiers: [], editing: true) == nil)
        }
        for editing in [true, false] {
            precondition(PlaybackShortcuts.command(for: "\u{1b}", modifiers: [], editing: editing) == "escape")
        }
        for flags: NSEvent.ModifierFlags in [.control, .option, [.command, .shift], [.command, .option]] {
            precondition(PlaybackShortcuts.command(for: "s", modifiers: flags, editing: false) == nil)
        }
        precondition(PlaybackShortcuts.command(for: "o", modifiers: .command, editing: true) == nil)
        precondition(PlaybackShortcuts.command(for: "x", modifiers: [], editing: false) == nil)
        print("PASS: command aliases, typing protection, Escape, passage keys, unrelated modifiers")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='murmur-shortcut-check-') as temp:
    swift = Path(temp) / 'ShortcutCheck.swift'
    binary = Path(temp) / 'ShortcutCheck'
    swift.write_text(source + harness)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(root / '.cache/clang'), str(swift), str(root / 'Sources/MarkdownPreview.swift'), '-o', str(binary), '-framework', 'SwiftUI', '-framework', 'AppKit', '-framework', 'AVFoundation', '-framework', 'WebKit'], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
