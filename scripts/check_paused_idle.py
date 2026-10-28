"""Exercise paused audio retention/resume and in-flight races via the real Reader.

A deterministic worker produces PCM WAVs without loading a model. --neural uses
Kokoro instead to additionally verify model unload/reload with real speech.
--headless simulates player timing when no audio output device is available.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/MarkdownVoice.swift').read_text().split('@main struct MarkdownVoiceApp:')[0]
source = source.replace('private let idleTimeout: TimeInterval = 60', 'private let idleTimeout: TimeInterval = 0.6')
fixture = r'''
import json, os, sys, tempfile, time, wave, math, struct
with tempfile.TemporaryDirectory(prefix='paused-check-') as temp:
    for line in sys.stdin:
        r = json.loads(line)
        if r['command'] == 'prepare':
            chunks = ['First prepared passage.', 'Second prepared passage.', 'Third prepared passage.']
            result = dict(chunks=chunks, speech_chunks=chunks, html='<p>Prepared test document</p>')
        else:
            time.sleep(0.9)  # Deliberately exceed the idle deadline.
            path = os.path.join(temp, r['id'] + '.wav')
            with wave.open(path, 'wb') as f:
                f.setparams((1, 2, 24000, 0, 'NONE', 'not compressed'))
                f.writeframes(b''.join(struct.pack('<h', int(1000*math.sin(i*0.05))) for i in range(24000*4)))
            result = dict(path=path)
        print(json.dumps(dict(id=r['id'], **result)), flush=True)
'''
headless_player = r'''
// Decode the real WAV with AVAudioPlayer, but simulate transport without hardware.
final class HeadlessAudioPlayer: AVAudioPlayer {
    private var transportRunning = false
    private var position: TimeInterval = 0
    private var startedAt: TimeInterval = 0
    private var completion: Timer?
    override var isPlaying: Bool { transportRunning }
    override var currentTime: TimeInterval {
        get { position + (transportRunning ? (ProcessInfo.processInfo.systemUptime - startedAt) * Double(rate) : 0) }
        set { position = newValue; startedAt = ProcessInfo.processInfo.systemUptime }
    }
    override func play() -> Bool {
        guard !transportRunning else { return true }
        transportRunning = true
        startedAt = ProcessInfo.processInfo.systemUptime
        completion?.invalidate()
        completion = Timer.scheduledTimer(withTimeInterval: max(0.01, (duration - position) / Double(rate)), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.position = self.duration
            self.transportRunning = false
            self.delegate?.audioPlayerDidFinishPlaying?(self, successfully: true)
        }
        return true
    }
    override func pause() {
        position = currentTime
        transportRunning = false
        completion?.invalidate()
    }
    override func stop() {
        transportRunning = false
        position = 0
        completion?.invalidate()
    }
}
'''
if '--headless' in sys.argv:
    source = source.replace('try AVAudioPlayer(contentsOf: url)', 'try HeadlessAudioPlayer(contentsOf: url)')
    source += headless_player

harness = r'''
extension Reader {
    // Same-file access exposes observations only; all transitions use Reader methods.
    var checkedWorker: Process? { process }
    var checkedPlayer: AVAudioPlayer? { player }
    var checkedQueue: [(Int, URL)] { queue }
    var checkedGenerating: Bool { generating }
    var checkedSpeech: [String] { speechChunks }
    var checkedAudioDirectory: URL { audioDirectory }
    var checkedPending: Bool { !callbacks.isEmpty }
}
@main struct PausedIdleCheck {
    static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    static func wait(_ reason: String, _ condition: () -> Bool) {
        print("Checking: \(reason)"); fflush(stdout)
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { spin(0.02) }
        precondition(condition(), reason)
    }
    static func main() {
        let reader = Reader()
        wait("Preview unavailable") { reader.previewHTML != "<p>Preparing preview…</p>" }
        reader.markdown = "First prepared passage. Keep this audio ready so I can resume at exactly the same position after the speech worker has released its memory.\n\nSecond prepared passage. This next passage should remain ready while paused, with the same voice, pronunciation, and audio bytes.\n\nThird prepared passage. Resume should load the worker again when more speech is needed without changing the document or skipping a passage."
        reader.start(paused: true)
        wait("Paused preparation unavailable") { !reader.checkedQueue.isEmpty }
        let prepared = reader.checkedQueue[0].1
        let bytes = try! Data(contentsOf: prepared)
        let chunks = reader.chunks, speech = reader.checkedSpeech
        let worker = reader.checkedWorker
        let temporaryDirectory = worker?.environment?["TMPDIR"]
        wait("Paused worker retained") { reader.checkedWorker == nil }
        if let worker { wait("Old process still alive") { !worker.isRunning } }
        if let temporaryDirectory {
            wait("Worker temporary directory retained") { !FileManager.default.fileExists(atPath: temporaryDirectory) }
        }
        precondition(reader.active && reader.paused && reader.current == 0)
        precondition(reader.chunks == chunks && reader.checkedSpeech == speech)
        precondition(try! Data(contentsOf: prepared) == bytes, "Queued audio changed/deleted")
        reader.togglePause()
        if let error = reader.error { fatalError("Resume failed: \(error)") }
        wait("Prepared passage did not resume") { reader.checkedPlayer?.isPlaying == true }
        let player = reader.checkedPlayer!
        player.volume = 0
        spin(0.1)
        reader.togglePause()
        let position = player.currentTime
        wait("Prefetch unavailable") { !reader.checkedQueue.isEmpty }
        let next = reader.checkedQueue[0].1
        let nextBytes = try! Data(contentsOf: next)
        wait("Prefetch worker retained") { reader.checkedWorker == nil }
        precondition(reader.checkedPlayer === player && abs(player.currentTime-position) < 0.03, "Paused position changed")
        precondition(try! Data(contentsOf: next) == nextBytes)
        // Interaction during pause extends the deadline without launching a worker.
        reader.refreshPreview()
        wait("Preview worker unavailable") { reader.checkedWorker != nil }
        spin(0.35); reader.userDidInteract(); spin(0.35)
        precondition(reader.checkedWorker?.isRunning == true, "Interaction failed to extend deadline")
        wait("Worker retained after interaction timeout") { reader.checkedWorker == nil }
        // Resume promptly, repause while synthesis is in flight, then resume again.
        reader.togglePause()
        precondition(reader.checkedPlayer === player && player.currentTime >= position-0.03)
        wait("Prefetch did not restart") { reader.checkedGenerating }
        reader.togglePause()
        spin(0.1); reader.togglePause()
        spin(0.7)
        precondition(reader.active && !reader.paused && reader.checkedWorker?.isRunning == true, "Active playback unloaded")
        wait("Queued passage did not play") { reader.current >= 1 }
        precondition(reader.error == nil, reader.error ?? "")
        reader.stop()
        wait("Stopped worker retained") { reader.checkedWorker == nil }
        precondition(reader.checkedWorker == nil && reader.checkedPlayer == nil && reader.checkedQueue.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: next.path), "Stopped queue leaked")
        // Replacing the input must discard old prepared audio and stale results.
        reader.start(paused: true)
        wait("Replacement setup missing") { !reader.checkedQueue.isEmpty }
        let oldAudio = reader.checkedQueue[0].1
        reader.stop(); reader.markdown = "Replacement document."; reader.documentChanged()
        precondition(!FileManager.default.fileExists(atPath: oldAudio.path), "Old input audio retained")
        precondition(reader.checkedPlayer == nil && reader.checkedQueue.isEmpty)
        reader.start(paused: true)
        wait("In-flight replacement setup missing") { reader.checkedGenerating }
        let replacedWorker = reader.checkedWorker!
        let replacedTemp = replacedWorker.environment!["TMPDIR"]!
        reader.stop(); reader.markdown = "Another replacement document."; reader.documentChanged()
        wait("Stale response did not drain") { !reader.checkedPending }
        precondition(reader.checkedQueue.isEmpty && reader.checkedPlayer == nil && reader.error == nil)
        precondition(!FileManager.default.fileExists(atPath: reader.checkedAudioDirectory.path), "Old retained directory leaked")
        wait("Replaced worker retained") { reader.checkedWorker == nil && !replacedWorker.isRunning }
        wait("Replaced worker files leaked") { !FileManager.default.fileExists(atPath: replacedTemp) }
        reader.start()
        wait("Natural completion did not finish") { !reader.active }
        precondition(reader.checkedPlayer == nil && reader.checkedQueue.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: reader.checkedAudioDirectory.path), "Finished audio directory leaked")
        reader.start(paused: true)
        wait("Shutdown setup missing") { !reader.checkedQueue.isEmpty }
        let shutdownAudio = reader.checkedQueue[0].1
        let shutdownWorker = reader.checkedWorker
        let shutdownTemp = shutdownWorker?.environment?["TMPDIR"]
        reader.shutdown()
        precondition(!FileManager.default.fileExists(atPath: shutdownAudio.path))
        precondition(!FileManager.default.fileExists(atPath: reader.checkedAudioDirectory.path))
        if let shutdownWorker { wait("Shutdown process survived") { !shutdownWorker.isRunning } }
        if let shutdownTemp { wait("Shutdown worker files leaked") { !FileManager.default.fileExists(atPath: shutdownTemp) } }
        print("PASS: paused initial generation, byte-identical queued audio, worker exit, exact player/position retention, activity reset, reload/prefetch, resume races, active playback protection, replacement/stale-result/completion/shutdown cleanup")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='audibleink-paused-check-') as temp:
    temp = Path(temp)
    swift = temp / 'PausedIdleCheck.swift'
    binary = temp / 'PausedIdleCheck'
    swift.write_text(source + harness)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(root / '.cache/clang'), str(swift), str(root / 'Sources/MarkdownPreview.swift'), '-o', str(binary), '-framework', 'SwiftUI', '-framework', 'AppKit', '-framework', 'AVFoundation', '-framework', 'WebKit', '-framework', 'PDFKit'], check=True)
    worker_root = root
    if '--neural' not in sys.argv:
        worker_root = temp / 'fixture'
        (worker_root / 'backend').mkdir(parents=True)
        (worker_root / '.venv/bin').mkdir(parents=True)
        (worker_root / '.venv/bin/python').symlink_to(sys.executable)
        (worker_root / 'backend/worker.py').write_text(fixture)
    subprocess.run([str(binary)], env={**os.environ, 'MARKDOWN_VOICE_ROOT': str(worker_root)}, check=True, timeout=180)
