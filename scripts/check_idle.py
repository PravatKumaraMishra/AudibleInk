"""Exercise the real Swift worker lifecycle with an accelerated idle timeout."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/MarkdownVoice.swift').read_text().split('struct ContentView: View {')[0]
source = source.replace('private let idleTimeout: TimeInterval = 60', 'private let idleTimeout: TimeInterval = 0.6')
harness = r'''
@main struct IdleCheck {
    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    static func worker(_ reader: Reader) -> Process? {
        Mirror(reflecting: reader).children.first { $0.label == "process" }?.value as? Process
    }
    static func waitForPreview(_ reader: Reader) {
        let deadline = Date().addingTimeInterval(10)
        while reader.previewHTML == "<p>Preparing preview…</p>" && Date() < deadline { spin(0.02) }
        precondition(reader.previewHTML != "<p>Preparing preview…</p>", "Preview did not load")
    }
    static func main() {
        let reader = Reader()
        waitForPreview(reader)
        let first = worker(reader)!
        spin(1.0)
        precondition(worker(reader) == nil, "Idle worker retained")
        let deadline = Date().addingTimeInterval(3)
        while first.isRunning && Date() < deadline { spin(0.02) }
        precondition(!first.isRunning, "Idle process still running")
        reader.refreshPreview()
        precondition(worker(reader) != nil, "Worker did not restart")
        reader.active = true; reader.paused = true
        spin(1.0)
        precondition(worker(reader)?.isRunning == true, "Paused reading lost worker")
        reader.stop()
        spin(1.0)
        precondition(worker(reader) == nil, "Stopped reader retained worker")
        reader.refreshPreview()
        precondition(worker(reader) != nil, "Second restart failed")
        reader.shutdown()
        precondition(worker(reader) == nil, "Shutdown retained worker")
        print("PASS: idle termination, restart, paused reading preservation, stop, shutdown")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='murmur-idle-check-') as temp:
    swift = Path(temp) / 'IdleCheck.swift'
    binary = Path(temp) / 'IdleCheck'
    swift.write_text(source + harness)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(root / '.cache/clang'), str(swift), '-o', str(binary), '-framework', 'SwiftUI', '-framework', 'AppKit', '-framework', 'AVFoundation'], check=True)
    subprocess.run([str(binary)], env={**os.environ, 'MARKDOWN_VOICE_ROOT': str(root)}, check=True, timeout=25)
