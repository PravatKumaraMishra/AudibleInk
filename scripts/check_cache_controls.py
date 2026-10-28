"""Check the real Reader/cache worker controls without loading Kokoro or playing sound."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import wave

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'backend'))
from worker import AudioCache

source = (root / 'Sources/MarkdownVoice.swift').read_text().split('@main struct MarkdownVoiceApp:')[0]
# Keep test preferences separate from the user's settings and draft.
source = source.replace('UserDefaults.standard', 'cacheTestDefaults')
source += r'''
let cacheTestSuite = "audibleink-cache-check-\(UUID().uuidString)"
let cacheTestDefaults = UserDefaults(suiteName: cacheTestSuite)!
extension Reader {
    var hasCachedQueue: Bool { !queue.isEmpty }
    func verifyQueuedCache() {
        precondition(queue.count == 1 && queuedCacheHits[queue[0].1] == true)
        playingCacheFile = queuedCacheFiles[queue[0].1]
        recordAudioPlayback()
        let modified = try! playingCacheFile!.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        precondition(abs(modified.timeIntervalSinceNow) < 2)
    }
}
@main struct CacheControlsCheck {
    static func wait(_ reason: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(condition(), reason)
    }
    static func main() {
        defer { cacheTestDefaults.removePersistentDomain(forName: cacheTestSuite) }
        let reader = Reader()
        defer { reader.shutdown() }
        wait("Initial cache usage missing") { reader.cacheFiles == 1 }
        reader.cacheLimitMB = 250
        reader.updateCacheLimit()
        wait("Size setting request stuck") { !reader.cacheBusy }
        precondition(cacheTestDefaults.integer(forKey: "audioCacheLimitMB") == 250)
        reader.markdown = "Hello"
        reader.start(paused: true)
        wait("Cached passage not prepared") { reader.hasCachedQueue }
        reader.verifyQueuedCache()
        reader.clearAudioCache()
        wait("Clear cache request stuck") { !reader.cacheBusy }
        precondition(reader.cacheBytes == 0 && reader.cacheFiles == 0 && !reader.active && !reader.hasCachedQueue)
        reader.privateAudio = true
        reader.updatePrivateAudio()
        precondition(cacheTestDefaults.bool(forKey: "privateAudio"))
        let restored = Reader()
        precondition(restored.cacheLimitMB == 250 && restored.privateAudio)
        restored.shutdown()
        print("PASS: cached prefetch, usage, playback timestamp, size preference, clear/stop, private preference, settings restored")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='audibleink-cache-controls-') as temp:
    temp = Path(temp)
    audio = temp / 'sample.wav'
    with wave.open(str(audio), 'wb') as output:
        output.setparams((1, 2, 24000, 0, 'NONE', 'not compressed'))
        output.writeframes(b'\x01\x00' * 2400)
    cache = AudioCache(temp / 'cache')
    cache.store(cache.key('Hello', 'af_heart', 1), audio)
    swift = temp / 'CacheControlsCheck.swift'
    swift.write_text(source)
    binary = temp / 'CacheControlsCheck'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path',
        str(root / '.cache/clang'), str(swift), str(root / 'Sources/MarkdownPreview.swift'), '-o', str(binary), '-framework', 'SwiftUI',
        '-framework', 'AppKit', '-framework', 'AVFoundation', '-framework', 'WebKit', '-framework', 'PDFKit'], check=True)
    subprocess.run([str(binary)], env={**os.environ, 'MARKDOWN_VOICE_ROOT': str(root),
        'AUDIBLEINK_AUDIO_CACHE': str(cache.directory)}, check=True, timeout=30)
