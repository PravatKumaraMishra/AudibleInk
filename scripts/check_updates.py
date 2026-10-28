"""Verify version checks and update errors using a local URLSession protocol."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/MarkdownVoice.swift').read_text().split('@main struct MarkdownVoiceApp:')[0]
source = source.replace('UserDefaults.standard', 'updateTestDefaults')
source += r'''
let updateTestSuite = "audibleink-updates-\(UUID().uuidString)"
let updateTestDefaults = UserDefaults(suiteName: updateTestSuite)!
final class UpdateFixture: URLProtocol {
    static var tag = "v1.3.0"
    static var status = 200
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        precondition(request.url == AppUpdates.latestURL)
        let body = "{\"tag_name\":\"\(Self.tag)\",\"html_url\":\"https://github.com/PravatKumaraMishra/AudibleInk/releases/tag/\(Self.tag)\",\"draft\":false,\"prerelease\":false}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct UpdateCheck {
    static func wait(_ reader: Reader) {
        let deadline = Date().addingTimeInterval(5)
        while reader.checkingForUpdates && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(!reader.checkingForUpdates)
    }
    static func main() {
        precondition(AppUpdates.isNewer("v1.10.0", than: "1.9.9"))
        precondition(!AppUpdates.isNewer("v1.2.1", than: "1.2.1"))
        precondition(!AppUpdates.isNewer("v1.2.0", than: "1.2.1"))
        precondition(!AppUpdates.isNewer("v1.3.0-beta", than: "1.2.1"))
        precondition(AppUpdates.releaseURL("https://example.com/update") == nil)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let reader = Reader()
        defer { reader.shutdown(); updateTestDefaults.removePersistentDomain(forName: updateTestSuite) }
        precondition(!reader.checkUpdatesOnLaunch)
        reader.checkUpdatesOnLaunch = true
        precondition(updateTestDefaults.bool(forKey: "checkUpdatesOnLaunch"))
        reader.checkUpdatesOnLaunch = false
        reader.checkForUpdates(session: session)
        reader.checkForUpdates(session: session)
        wait(reader)
        precondition(UpdateFixture.requests == 1)
        precondition(reader.availableUpdateVersion == "v1.3.0")
        precondition(reader.availableUpdateURL != nil)
        UpdateFixture.tag = "v1.2.1"
        reader.checkForUpdates(session: session); wait(reader)
        precondition(reader.availableUpdateURL == nil)
        precondition(reader.updateMessage.contains("up to date"))
        UpdateFixture.status = 403
        reader.checkForUpdates(session: session); wait(reader)
        precondition(reader.updateMessage.contains("Couldn't check"))
        AppUpdates.session = session
        defer { AppUpdates.session = .shared }
        UpdateFixture.status = 200
        UpdateFixture.tag = "v1.3.0"
        updateTestDefaults.set(true, forKey: "checkUpdatesOnLaunch")
        let before = UpdateFixture.requests
        let launched = Reader()
        defer { launched.shutdown() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        wait(launched)
        precondition(UpdateFixture.requests == before + 1)
        precondition(launched.availableUpdateVersion == "v1.3.0")
        print("PASS: opt-in launch checks; numeric versions, release URL validation, opt-in persistence, manual checks, duplicate checks, current version, HTTP errors")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='audibleink-update-check-') as temporary:
    temporary = Path(temporary)
    swift, binary = temporary / 'UpdateCheck.swift', temporary / 'UpdateCheck'
    swift.write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(root / '.cache/clang'), str(swift), str(root / 'Sources/MarkdownPreview.swift'), '-o', str(binary), '-framework', 'SwiftUI', '-framework', 'AppKit', '-framework', 'AVFoundation', '-framework', 'WebKit', '-framework', 'PDFKit'], check=True)
    subprocess.run([str(binary)], env={**os.environ, 'MARKDOWN_VOICE_ROOT': str(root)}, check=True, timeout=20)
