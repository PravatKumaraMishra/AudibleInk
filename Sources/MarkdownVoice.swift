import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import PDFKit

struct GitHubRelease: Decodable {
    let tag_name: String
    let html_url: String
    let draft: Bool
    let prerelease: Bool
}

enum AppUpdates {
    static var session = URLSession.shared
    static let latestURL = URL(string: "https://api.github.com/repos/PravatKumaraMishra/AudibleInk/releases/latest")!
    static var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.1" }
    static func versionNumbers(_ version: String) -> [Int]? {
        let clean = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let pieces = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == pieces.count else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
    static func isNewer(_ tag: String, than current: String) -> Bool {
        guard let remote = versionNumbers(tag), let local = versionNumbers(current) else { return false }
        return local.lexicographicallyPrecedes(remote)
    }
    static func releaseURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.hasPrefix("/PravatKumaraMishra/AudibleInk/releases/tag/") else { return nil }
        return url
    }
}

struct Voice: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
}

struct ReferenceVoice: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var path: String
    var transcript: String
}

struct SpeechModel: Identifiable {
    let id: String
    let name: String
    let resources: String
    static let all = [
        SpeechModel(id: "kokoro", name: "Kokoro", resources: "Download ≈ 350 MB · working RAM ≈ 1–2 GB"),
        SpeechModel(id: "soprano", name: "Soprano 80M", resources: "Download ≈ 200 MB · working RAM ≈ 1–2 GB"),
        SpeechModel(id: "svara", name: "Svara v1 · 4-bit", resources: "Download ≈ 2 GB + shared decoder · working RAM ≈ 3–6 GB"),
        SpeechModel(id: "indicf5", name: "IndicF5-MLX", resources: "Allow ≈ 5 GB storage for weights/conversion · working RAM ≈ 4–8 GB")
    ]
}

enum DocumentImport {
    static func text(from url: URL) throws -> String {
        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let document = PDFDocument(url: url), !document.isLocked else {
                throw NSError(domain: "DocumentImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "This PDF could not be opened. It may be damaged or password protected."])
            }
            text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        case "doc", "docx", "rtf":
            let type: NSAttributedString.DocumentType = url.pathExtension.lowercased() == "docx" ? .officeOpenXML : (url.pathExtension.lowercased() == "doc" ? .docFormat : .rtf)
            text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
        default:
            text = try String(contentsOf: url, encoding: .utf8)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "DocumentImport", code: 2, userInfo: [NSLocalizedDescriptionKey: "No readable text was found. Scanned PDFs need OCR before importing."])
        }
        // Keep extracted prose literal: document punctuation is not Markdown markup.
        if ["pdf", "doc", "docx", "rtf"].contains(url.pathExtension.lowercased()) {
            let markup = Set("\\`*_{}[]<>#!|~+.-")
            return text.map { markup.contains($0) ? "\\" + String($0) : String($0) }.joined()
        }
        return text
    }
}

struct RecentDocument: Codable, Identifiable {
    var id: String
    var title: String
    var path: String?
    var text: String?
}

final class Reader: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var markdown = "# A little space to listen\n\nPaste your Markdown here, or open a file. Turn your notes, articles, and ideas into a voice you can take your time with.\n\n## Made for your Mac\n\nListen with Heart or choose another Kokoro voice for local neural speech.\n\n- Your words stay on this machine.\n- Links and formatting become clean, readable speech.\n- Code blocks are skipped unless you include them."
    @Published var voice = ""
    @Published var showSettings = false
    @Published var settingsTab = "general"
    @Published var floating = false
    @Published var alwaysOnTop = UserDefaults.standard.bool(forKey: "alwaysOnTop") {
        didSet { UserDefaults.standard.set(alwaysOnTop, forKey: "alwaysOnTop"); floatingWindow?.level = alwaysOnTop ? .floating : .normal }
    }
    @Published var checkUpdatesOnLaunch = UserDefaults.standard.bool(forKey: "checkUpdatesOnLaunch") {
        didSet { UserDefaults.standard.set(checkUpdatesOnLaunch, forKey: "checkUpdatesOnLaunch") }
    }
    @Published var checkingForUpdates = false
    @Published var updateMessage = "Check GitHub for a newer version of AudibleInk."
    @Published var availableUpdateURL: URL?
    @Published var availableUpdateVersion = ""
    func checkForUpdates(session: URLSession = AppUpdates.session) {
        guard !checkingForUpdates else { return }
        checkingForUpdates = true
        updateMessage = "Checking for updates…"
        var request = URLRequest(url: AppUpdates.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AudibleInk/\(AppUpdates.installedVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingForUpdates = false
                guard error == nil, let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data, let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                      !release.draft, !release.prerelease,
                      AppUpdates.versionNumbers(release.tag_name) != nil,
                      let url = AppUpdates.releaseURL(release.html_url) else {
                    self.updateMessage = "Couldn't check for updates. Check your connection and try again."
                    return
                }
                if AppUpdates.isNewer(release.tag_name, than: AppUpdates.installedVersion) {
                    self.availableUpdateURL = url
                    self.availableUpdateVersion = release.tag_name
                    self.updateMessage = "\(release.tag_name) is available. Download it from GitHub to update."
                } else {
                    self.availableUpdateURL = nil
                    self.availableUpdateVersion = ""
                    self.updateMessage = "You're up to date (\(AppUpdates.installedVersion))."
                }
            }
        }.resume()
    }
    func openAvailableUpdate() {
        if let url = availableUpdateURL { NSWorkspace.shared.open(url) }
    }
    @Published var recentDocuments: [RecentDocument] = []
    private var currentDocumentID = UserDefaults.standard.string(forKey: "currentDocumentID")
    @Published var renamingDocumentID: String?
    @Published var renameText = ""
    @Published var uiMode = UserDefaults.standard.string(forKey: "uiMode") ?? "system" {
        didSet { UserDefaults.standard.set(uiMode, forKey: "uiMode"); applyAppearance() }
    }
    func applyAppearance() {
        guard let application = NSApp else { return }
        application.appearance = uiMode == "dark" ? NSAppearance(named: .darkAqua) : (uiMode == "light" ? NSAppearance(named: .aqua) : nil)
    }
    private var loadingDocument = false
    private var nextUntitled = max(1, UserDefaults.standard.integer(forKey: "nextUntitled"))

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentDocuments) { UserDefaults.standard.set(data, forKey: "recentDocuments") }
        UserDefaults.standard.set(currentDocumentID, forKey: "currentDocumentID")
        UserDefaults.standard.set(filename, forKey: "filename")
    }
    func newDraft() {
        saveDraft()
        stop(); currentDocumentID = nil; markdown = ""; filename = "New document"
        UserDefaults.standard.set(markdown, forKey: "document")
        saveRecents()
        preview = false
        NotificationCenter.default.post(name: .init("FocusInput"), object: nil)
    }
    func beginPaste(replacingDocument: Bool) {
        if replacingDocument {
            saveDraft()
            currentDocumentID = nil
        }
    }
    func saveDraft() {
        guard !loadingDocument, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = recentDocuments.firstIndex(where: { $0.id == currentDocumentID }) {
            if recentDocuments[index].text == markdown { return }
            if recentDocuments[index].path == nil {
                recentDocuments[index].text = markdown
                saveRecents(); return
            }
            // An edited import becomes a separate draft; the file stays untouched.
        }
        let title = "Untitled \(nextUntitled)"
        nextUntitled += 1
        UserDefaults.standard.set(nextUntitled, forKey: "nextUntitled")
        let document = RecentDocument(id: UUID().uuidString, title: title, text: markdown)
        recentDocuments.insert(document, at: 0)
        currentDocumentID = document.id; filename = title
        saveRecents()
    }
    func openRecent(_ document: RecentDocument) {
        saveDraft()
        if let path = document.path { openDocument(URL(fileURLWithPath: path)); return }
        stop(); loadingDocument = true
        currentDocumentID = document.id; markdown = document.text ?? ""; filename = document.title
        UserDefaults.standard.set(markdown, forKey: "document")
        recentDocuments.removeAll { $0.id == document.id }; recentDocuments.insert(document, at: 0)
        saveRecents(); refreshPreview()
        DispatchQueue.main.async { self.loadingDocument = false }
    }
    func removeRecent(_ document: RecentDocument) {
        recentDocuments.removeAll { $0.id == document.id }
        if renamingDocumentID == document.id { renamingDocumentID = nil }
        if currentDocumentID == document.id {
            stop()
            loadingDocument = true
            currentDocumentID = nil
            markdown = ""
            filename = "New document"
            UserDefaults.standard.removeObject(forKey: "document")
            refreshPreview()
            DispatchQueue.main.async { self.loadingDocument = false }
        }
        saveRecents()
    }

    func renameRecent(_ document: RecentDocument) {
        renamingDocumentID = document.id; renameText = document.title
    }
    func finishRename() {
        defer { renamingDocumentID = nil }
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let index = recentDocuments.firstIndex(where: { $0.id == renamingDocumentID }) else { return }
        recentDocuments[index].title = title
        if currentDocumentID == renamingDocumentID { filename = title }
        saveRecents()
    }
    @Published var shortcuts = ShortcutBinding.load() {
        didSet { if let data = try? JSONEncoder().encode(shortcuts) { UserDefaults.standard.set(data, forKey: "shortcuts") } }
    }
    weak var mainWindow: NSWindow?
    private var floatingWindow: NSWindow?
    func openSettings(_ tab: String = "general") { settingsTab = tab; showSettings = true }
    func toggleFloating() {
        if floating {
            floatingWindow?.orderOut(nil); mainWindow?.makeKeyAndOrderFront(nil); floating = false
        } else {
            if floatingWindow == nil {
                let window = NSPanel(contentRect: NSRect(x: 150, y: 150, width: 440, height: 210), styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
                window.title = "AudibleInk Player"
                window.minSize = NSSize(width: 440, height: 210)
                window.isReleasedWhenClosed = false
                window.hidesOnDeactivate = false
                window.contentView = NSHostingView(rootView: FloatingPlayer(reader: self))
                floatingWindow = window
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    self?.floating = false; self?.mainWindow?.makeKeyAndOrderFront(nil)
                }
            }
            floating = true
            floatingWindow?.level = alwaysOnTop ? .floating : .normal
            floatingWindow?.makeKeyAndOrderFront(nil)
            mainWindow?.orderOut(nil)
        }
    }
    @Published var deletingModel = false
    @Published var modelMessage = "Downloads on first use; runs locally afterward."
    func deleteModel(_ engine: String) {
        guard !deletingModel else { return }
        deletingModel = true
        modelMessage = "Deleting downloaded model…"
        stop()
        request(["command": "delete_model", "engine": engine]) { [weak self] response in
            self?.deletingModel = false
            if let message = response["error"] as? String { self?.error = message; self?.modelMessage = message }
            else { self?.status = "Model deleted · downloads again on next use"; self?.modelMessage = "Deleted. The model downloads again on next use." }
            self?.refreshModelStorage()
        }
    }
    @Published var focusDocument = false
    @Published var speed = 1.0
    @Published var includeCode = false
    @Published var status = "Ready when you are"
    @Published var active = false
    @Published var paused = false
    @Published var chunks: [String] = []
    @Published var current = 0
    @Published var preview = false
    @Published var previewHTML = "<p>Preparing preview…</p>"
    @Published var followReading = (UserDefaults.standard.object(forKey: "followReading") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(followReading, forKey: "followReading") }
    }
    @Published var showPronunciations = false
    @Published var showShortcuts = false
    @Published var showListeningTip = false
    @Published var showCacheSettings = false
    @Published var cacheLimitMB = 1024
    @Published var privateAudio = false
    @Published var cacheBytes: Int64 = 0
    @Published var cacheFiles = 0
    @Published var cacheBusy = false
    private var queuedCacheHits: [URL: Bool] = [:]
    private var playingCacheHit = false
    private var sessionPrivateAudio = false
    @Published var technical = true
    @Published var pronunciations = "API = A P I\nREST = rest\nJSON = jay son\nSQL = sequel\nJPA = J P A\nJVM = J V M\nHTTP = H T T P\nHTTPS = H T T P S\nURI = U R I\nURL = U R L\nCRUD = crud\nDTO = D T O\nDAO = D A O\nHATEOAS = hate ee oss\nOAuth = oh auth\nPostgreSQL = post gress Q L\nMySQL = my sequel\n@GetMapping = get mapping\n@RestController = rest controller"
    private var speechChunks: [String] = []
    private var previewRevision = UUID()
    private var refreshWork: DispatchWorkItem?
    @Published var filename = UserDefaults.standard.string(forKey: "filename") ?? "Untitled.md"
    @Published var error: String?
    let baseVoices: [Voice]
    @Published var referenceVoices: [ReferenceVoice] = []
    @Published var selectedModel = "kokoro"
    @Published var modelBytes: [String: Int64] = [:]
    var voices: [Voice] {
        baseVoices + referenceVoices.map { Voice(id: "indicf5:\($0.id)", name: $0.name, detail: "Reference voice · IndicF5") }
    }
    var modelVoices: [Voice] { voices.filter { $0.id.hasPrefix(selectedModel + ":") } }
    func selectModel() {
        if !modelVoices.contains(where: { $0.id == voice }) { voice = modelVoices.first?.id ?? "" }
        UserDefaults.standard.set(selectedModel, forKey: "speechModel")
    }
    func refreshModelStorage() {
        request(["command": "model_info"]) { [weak self] response in
            if let usage = response["model_bytes"] as? [String: NSNumber] {
                self?.modelBytes = usage.mapValues { $0.int64Value }
            }
        }
    }
    func saveReferenceVoices() {
        if let data = try? JSONEncoder().encode(referenceVoices) { UserDefaults.standard.set(data, forKey: "referenceVoices") }
        selectModel()
    }
    func chooseReferenceAudio() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .audio]
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    private var idleWork: DispatchWorkItem?
    private let idleTimeout: TimeInterval = 60
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    private var activityMonitor: Any?
    private let audioDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("audibleink-audio-\(UUID().uuidString)", isDirectory: true)
    private var player: AVAudioPlayer?
    private var queuedCacheFiles: [URL: URL] = [:]
    private var playingCacheFile: URL?
    private var process: Process?
    private var input: FileHandle?
    private let writer = DispatchQueue(label: "audibleink.worker-input")
    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    private var buffer = Data()
    private var generation = UUID()
    private var nextIndex = 0
    private var generating = false
    private var queue: [(Int, URL)] = []
    private var selectedVoice = ""
    private var diagnostics = ""

    override init() {
        let list = [Voice(id: "kokoro:af_heart", name: "Heart", detail: "American · Kokoro"),
                 Voice(id: "kokoro:af_bella", name: "Bella", detail: "American · Kokoro"),
                 Voice(id: "kokoro:am_michael", name: "Michael", detail: "American · Kokoro"),
                 Voice(id: "kokoro:bf_emma", name: "Emma", detail: "British · Kokoro"),
                 Voice(id: "kokoro:bm_george", name: "George", detail: "British · Kokoro")]
        let languages = ["Hindi", "Bengali", "English (Indian)", "Marathi", "Telugu", "Kannada", "Tamil", "Malayalam", "Gujarati", "Punjabi", "Assamese", "Bhojpuri", "Magahi", "Maithili", "Chhattisgarhi", "Bodo", "Dogri", "Nepali", "Sanskrit"]
        baseVoices = list + [Voice(id: "soprano:default", name: "Soprano", detail: "English · Soprano 80M"), Voice(id: "kokoro:hf_alpha", name: "Alpha", detail: "Hindi · Kokoro"), Voice(id: "kokoro:hm_omega", name: "Omega", detail: "Hindi · Kokoro")] + languages.flatMap { language in
            ["Female", "Male"].map { gender in Voice(id: "svara:\(language) (\(gender))", name: "\(language) · \(gender)", detail: "Svara v1 · 4-bit") }
        }

        super.init()
        applyAppearance()
        if let data = UserDefaults.standard.data(forKey: "referenceVoices"), let saved = try? JSONDecoder().decode([ReferenceVoice].self, from: data) { referenceVoices = saved }
        voice = UserDefaults.standard.string(forKey: "voice").flatMap { saved in voices.contains(where: { $0.id == saved }) ? saved : nil } ?? "kokoro:af_heart"
        let savedModel = UserDefaults.standard.string(forKey: "speechModel") ?? String(voice.split(separator: ":").first ?? "kokoro")
        selectedModel = SpeechModel.all.contains(where: { $0.id == savedModel }) ? savedModel : "kokoro"
        selectModel()
        let savedLimit = UserDefaults.standard.integer(forKey: "audioCacheLimitMB")
        if [100, 250, 500, 1024, 2048, 5120, 10240].contains(savedLimit) { cacheLimitMB = savedLimit }
        privateAudio = UserDefaults.standard.bool(forKey: "privateAudio")
        if let saved = UserDefaults.standard.string(forKey: "document") { markdown = saved }
        if let saved = UserDefaults.standard.string(forKey: "pronunciations") { pronunciations = saved }
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.userDidInteract()
            return event
        }
        if let data = UserDefaults.standard.data(forKey: "recentDocuments"), let documents = try? JSONDecoder().decode([RecentDocument].self, from: data) {
            recentDocuments = documents
        } else {
            recentDocuments = (UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []).map { RecentDocument(id: $0, title: URL(fileURLWithPath: $0).lastPathComponent, path: $0) }
        }
        if UserDefaults.standard.string(forKey: "document") != nil { saveDraft() }
        refreshPreview()
        if checkUpdatesOnLaunch {
            DispatchQueue.main.async { [weak self] in self?.checkForUpdates() }
        }
    }

    // Successful playback marks this WAV as recently used for size-based eviction.
    private func recordAudioPlayback() {
        guard let url = playingCacheFile else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    var cacheUsage: String {
        ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private var readingStatus: String {
        playingCacheHit ? "Playing saved audio" : "Playing generated audio"
    }

    func refreshCacheInfo() {
        cacheBusy = true
        request(["command": "cache_info"]) { [weak self] response in
            self?.cacheBusy = false
            if let message = response["error"] as? String { self?.error = message }
        }
    }

    func updateCacheLimit() {
        UserDefaults.standard.set(cacheLimitMB, forKey: "audioCacheLimitMB")
        refreshCacheInfo()
    }

    func updatePrivateAudio() {
        stop()
        UserDefaults.standard.set(privateAudio, forKey: "privateAudio")
    }

    func clearAudioCache() {
        // The worker handles this after any in-flight synthesis, so cleared audio
        // cannot be republished by an earlier request. Stop also discards prefetch.
        stop()
        cacheBusy = true
        request(["command": "cache_clear"]) { [weak self] response in
            guard let self else { return }
            self.cacheBusy = false
            if let message = response["error"] as? String { self.error = message }
            else { self.status = "Audio cache cleared" }
        }
    }

    deinit {
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        try? FileManager.default.removeItem(at: audioDirectory)
    }

    var wordCount: Int { markdown.split(whereSeparator: { $0.isWhitespace }).count }

    // App input resets inactivity; worker replies do not extend the deadline.
    func userDidInteract() {
        lastInteraction = ProcessInfo.processInfo.systemUptime
        scheduleIdleRelease()
    }

    private func scheduleIdleRelease() {
        idleWork?.cancel(); idleWork = nil
        guard process != nil, !active || paused else { return }
        let remaining = max(0, idleTimeout - (ProcessInfo.processInfo.systemUptime - lastInteraction))
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.active || self.paused else { return }
            // Let an in-flight prepare/synthesis finish, then receive() retries using
            // the original deadline. This preserves prepared audio and callbacks.
            guard self.callbacks.isEmpty else { return }
            self.releaseWorker()
            if self.active {
                self.status = "Paused · speech memory released"
            } else {
                self.speechChunks.removeAll()
                self.status = "Speech memory released · ready to reload"
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func releaseWorker() {
        idleWork?.cancel(); idleWork = nil
        let task = process
        process = nil
        (task?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (task?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close(); input = nil
        callbacks.removeAll(); buffer.removeAll(); diagnostics = ""
        if task?.isRunning == true { task?.terminate() }
    }
    var progress: Double { chunks.isEmpty ? 0 : Double(current) / Double(chunks.count) }

    func launchWorker() throws {
        if process?.isRunning == true { return }
        let resources = Bundle.main.resourceURL!
        let root = ProcessInfo.processInfo.environment["MARKDOWN_VOICE_ROOT"].map { URL(fileURLWithPath: $0) }
        let configuredPath = (try? String(contentsOf: resources.appendingPathComponent("runtime-path.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledPython = resources.appendingPathComponent("python/bin/python3.11")
        let python = root?.appendingPathComponent(".venv/bin/python") ?? (FileManager.default.isExecutableFile(atPath: bundledPython.path) ? bundledPython : URL(fileURLWithPath: configuredPath ?? ""))
        let worker = root?.appendingPathComponent("backend/worker.py") ?? resources.appendingPathComponent("worker.py")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw NSError(domain: "Reader", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Python runtime is missing. Run scripts/setup.sh, then scripts/build.sh."])
        }
        let workerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("audibleink-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workerDirectory, withIntermediateDirectories: true)
        let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = python
        task.arguments = ["-u", worker.path]
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = workerDirectory.path
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["HF_HUB_DISABLE_XET"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")
        env["HF_HOME"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MarkdownVoice/huggingface").path
        task.environment = env
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.receive(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self, weak task] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.diagnostics = String(self.diagnostics.suffix(2000)) + (String(data: data, encoding: .utf8) ?? "")
            }
        }
        task.terminationHandler = { [weak self] task in
            try? FileManager.default.removeItem(at: workerDirectory)
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.process = nil; self.callbacks.removeAll(); self.buffer.removeAll()
                if self.active { self.fail("Speech worker stopped. \(self.diagnostics.suffix(700))") }
            }
        }
        do { try task.run() }
        catch { try? FileManager.default.removeItem(at: workerDirectory); throw error }
        process = task; input = stdin.fileHandleForWriting
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if message["event"] as? String == "setup", let detail = message["message"] as? String {
                if active { status = detail }
                continue
            }
            guard let id = message["id"] as? String else { continue }
            if let bytes = message["cache_bytes"] as? NSNumber { cacheBytes = bytes.int64Value }
            if let count = message["cache_files"] as? Int { cacheFiles = count }
            callbacks.removeValue(forKey: id)?(message)
            if callbacks.isEmpty { scheduleIdleRelease() }
        }
    }

    private func request(_ payload: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        idleWork?.cancel()
        do {
            try launchWorker()
            let id = UUID().uuidString
            var object = payload; object["id"] = id
            object["cache_limit_bytes"] = cacheLimitMB * 1024 * 1024
            var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
            callbacks[id] = completion
            let payload = data
            let handle = input!
            writer.async { [weak self] in
                do { try handle.write(contentsOf: payload) }
                catch {
                    DispatchQueue.main.async {
                        guard let self, self.callbacks.removeValue(forKey: id) != nil else { return }
                        self.fail(error.localizedDescription)
                    }
                }
            }
        } catch { fail(error.localizedDescription) }
    }

    func documentChanged() {
        userDidInteract()
        UserDefaults.standard.set(markdown, forKey: "document")
        saveDraft()
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func refreshPreview() {
        userDidInteract()
        let revision = UUID(); previewRevision = revision
        request(["command": "prepare", "text": markdown, "include_code": includeCode]) { [weak self] response in
            guard let self, self.previewRevision == revision else { return }
            if let html = response["html"] as? String { self.previewHTML = html }
            else if let error = response["error"] as? String { self.error = error }
        }
    }

    func start(at index: Int = 0, paused initiallyPaused: Bool = false) {
        saveDraft()
        if let index = recentDocuments.firstIndex(where: { $0.id == currentDocumentID }) { let document = recentDocuments.remove(at: index); recentDocuments.insert(document, at: 0); saveRecents() }
        stop()
        error = nil
        guard !voice.isEmpty else { error = "Add an IndicF5 reference voice in Settings before listening."; openSettings(); return }
        active = true; paused = initiallyPaused; status = "Preparing your Markdown…"
        selectedVoice = voice
        sessionPrivateAudio = privateAudio
        let session = generation
        UserDefaults.standard.set(pronunciations, forKey: "pronunciations")
        request(["command": "prepare", "text": markdown, "include_code": includeCode, "pronunciations": pronunciations, "technical": technical]) { [weak self] response in
            guard let self, self.generation == session else { return }
            if let error = response["error"] as? String { self.fail(error); return }
            self.chunks = response["chunks"] as? [String] ?? []
            self.speechChunks = response["speech_chunks"] as? [String] ?? self.chunks
            if let html = response["html"] as? String { self.previewHTML = html }
            guard !self.chunks.isEmpty else { self.fail("Add some readable text first."); return }
            self.current = max(0, min(index, self.chunks.count - 1))
            self.nextIndex = self.current
            self.preview = true
            self.fillQueue()
        }
    }

    private func fillQueue() {
        guard active, !generating, queue.isEmpty, nextIndex < chunks.count else { return }
        generating = true
        let index = nextIndex; nextIndex += 1
        let session = generation
        if player == nil { status = sessionPrivateAudio ? "Generating private audio…" : "Checking saved audio… Generating if needed." }
        var payload: [String: Any] = ["command": "synth", "text": speechChunks[index], "voice": String(selectedVoice.split(separator: ":", maxSplits: 1)[1]), "engine": String(selectedVoice.split(separator: ":", maxSplits: 1)[0]), "speed": 1.0, "private": sessionPrivateAudio]
        if let reference = referenceVoices.first(where: { "indicf5:" + $0.id == selectedVoice }) {
            payload["reference_audio"] = reference.path
            payload["reference_text"] = reference.transcript
        }
        request(payload) { [weak self] response in
            guard let self else { return }
            guard self.generation == session else {
                if let path = response["path"] as? String { try? FileManager.default.removeItem(atPath: path) }
                return
            }
            self.generating = false
            if let error = response["error"] as? String { self.fail(error); return }
            guard let path = response["path"] as? String else { self.fail("No audio received from the model."); return }
            // Keep queued audio outside the worker's temporary directory so a
            // paused idle release cannot invalidate a prepared passage.
            let source = URL(fileURLWithPath: path)
            let retained = self.audioDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            do {
                try FileManager.default.createDirectory(at: self.audioDirectory, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: source, to: retained)
            } catch {
                try? FileManager.default.removeItem(at: source)
                self.fail("Could not retain prepared audio: \(error.localizedDescription)"); return
            }
            if let key = response["cache_key"] as? String,
               key.count == 64, key.allSatisfy({ "0123456789abcdef".contains($0) }) {
                let directory = ProcessInfo.processInfo.environment["AUDIBLEINK_AUDIO_CACHE"]
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Caches/MarkdownVoice/audio", isDirectory: true)
                self.queuedCacheFiles[retained] = directory.appendingPathComponent("\(key).wav")
            }
            self.queuedCacheHits[retained] = response["cache_hit"] as? Bool ?? false
            self.queue.append((index, retained))
            self.playNext()
        }
    }

    private func playNext() {
        guard active, !paused, player == nil else { return }
        guard !queue.isEmpty else {
            if nextIndex == chunks.count && !generating { finish() } else { fillQueue() }
            return
        }
        let (index, url) = queue.removeFirst()
        playingCacheFile = queuedCacheFiles.removeValue(forKey: url)
        playingCacheHit = queuedCacheHits.removeValue(forKey: url) ?? false
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.enableRate = true
            audio.rate = Float(speed)
            audio.delegate = self
            player = audio; current = index
            guard audio.play() else { throw NSError(domain: "Reader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio playback could not start. Check that an audio output device is connected and selected in System Settings → Sound."]) }
            recordAudioPlayback()
            status = readingStatus
            fillQueue()
        } catch { fail(error.localizedDescription) }
    }

    func updatePlaybackSpeed() {
        speed = min(2.0, max(0.5, speed))
        player?.rate = Float(speed)
    }

    func togglePlayback() {
        if active { togglePause() }
        else if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { start() }
    }

    func toggleStartStop() {
        if active { stop() }
        else if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { start() }
    }

    func movePassage(by offset: Int) {
        guard active, !chunks.isEmpty else { return }
        let target = max(0, min(chunks.count - 1, current + offset))
        guard target != current else { return }
        start(at: target, paused: paused)
    }

    func togglePause() {
        guard active else { return }
        paused.toggle()
        userDidInteract()
        if paused {
            player?.pause(); status = "Paused"
        } else {
            if let player {
                guard player.play() else { fail("Audio playback could not resume. Check your audio output in System Settings → Sound."); return }
                recordAudioPlayback()
                status = readingStatus
                fillQueue()
            } else { playNext() }
        }
    }

    func stop() {
        generation = UUID(); active = false; paused = false
        player?.stop(); player = nil
        queuedCacheFiles.removeAll(); playingCacheFile = nil
        queuedCacheHits.removeAll(); playingCacheHit = false
        for (_, url) in queue { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: audioDirectory)
        queue.removeAll(); generating = false; nextIndex = 0; current = 0; chunks = []; speechChunks = []
        userDidInteract()
        status = "Ready when you are"
    }
    private func finish() {
        active = false; paused = false; current = chunks.count
        status = "Finished. A little more clarity."
        speechChunks.removeAll()
        try? FileManager.default.removeItem(at: audioDirectory)
        userDidInteract()
    }
    private func fail(_ message: String) { if deletingModel { deletingModel = false; modelMessage = message }; cacheBusy = false; stop(); error = message; status = "Something needs attention" }
    func quit() {
        shutdown()
        NSApplication.shared.terminate(nil)
    }
    func shutdown() {
        stop(); releaseWorker()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }; activityMonitor = nil
        try? FileManager.default.removeItem(at: audioDirectory)
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        self.player = nil
        playingCacheFile = nil
        if flag { playNext() } else { fail("Audio playback was interrupted. Try reading again.") }
    }
    @Published var importing = false
    func openFile() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .pdf, .rtf] + ["md", "markdown", "doc", "docx"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDocument(url)
    }
    func openDocument(_ url: URL) {
        guard !importing else { return }
        saveDraft()
        importing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DocumentImport.text(from: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.importing = false
                switch result {
                case .success(let text):
                    self.stop(); self.loadingDocument = true
                    let old = self.recentDocuments.first { $0.path == url.path }
                    let document = RecentDocument(id: old?.id ?? UUID().uuidString, title: old?.title ?? url.lastPathComponent, path: url.path, text: text)
                    self.recentDocuments.removeAll { $0.path == url.path }; self.recentDocuments.insert(document, at: 0)
                    self.currentDocumentID = document.id; self.markdown = text; self.filename = document.title
                    self.saveRecents(); self.documentChanged()
                    DispatchQueue.main.async { self.loadingDocument = false }
                case .failure(let error): self.error = "Could not import document: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct ShortcutBinding: Codable, Identifiable {
    var id: String
    var title: String
    var key: String
    var modifiers: UInt
    static let defaults: [ShortcutBinding] = [
        .init(id: " ", title: "Play / Pause / Resume", key: "space", modifiers: 0),
        .init(id: "startStop", title: "Start / Stop", key: "s", modifiers: NSEvent.ModifierFlags.command.rawValue),
        .init(id: "s", title: "Stop", key: "s", modifiers: 0),
        .init(id: "i", title: "Focus input", key: "i", modifiers: 0),
        .init(id: "escape", title: "Leave input", key: "escape", modifiers: 0),
        .init(id: "[", title: "Slower", key: "[", modifiers: 0),
        .init(id: "]", title: "Faster", key: "]", modifiers: 0),
        .init(id: "preview", title: "Input / Preview", key: "p", modifiers: NSEvent.ModifierFlags.command.rawValue),
        .init(id: "follow", title: "Follow reading", key: "f", modifiers: NSEvent.ModifierFlags.command.rawValue),
        .init(id: "previous", title: "Previous passage", key: "left", modifiers: NSEvent.ModifierFlags.command.rawValue),
        .init(id: "next", title: "Next passage", key: "right", modifiers: NSEvent.ModifierFlags.command.rawValue),
        .init(id: "fullscreen", title: "Full screen", key: "f", modifiers: NSEvent.ModifierFlags.option.rawValue),
        .init(id: "floating", title: "Main / Floating player", key: "t", modifiers: NSEvent.ModifierFlags.command.rawValue),
        .init(id: "settings", title: "Settings", key: ",", modifiers: NSEvent.ModifierFlags.command.rawValue),
        .init(id: "open", title: "Open document", key: "o", modifiers: NSEvent.ModifierFlags.command.rawValue)
    ]
    static func load() -> [ShortcutBinding] {
        guard let data = UserDefaults.standard.data(forKey: "shortcuts"), let saved = try? JSONDecoder().decode([ShortcutBinding].self, from: data) else { return defaults }
        return defaults.map { item in saved.first(where: { $0.id == item.id }) ?? item }
    }
    static func normalized(_ key: String) -> String {
        switch key {
        case " ": return "space"
        case "\r": return "return"
        case "\u{1b}": return "escape"
        case "\u{f702}": return "left"
        case "\u{f703}": return "right"
        default: return key.lowercased()
        }
    }
}

extension Reader {
    func perform(_ command: String) {
        switch command {
        case " ": togglePlayback()
        case "s": stop()
        case "startStop": toggleStartStop()
        case "escape": NSApp.keyWindow?.makeFirstResponder(nil)
        case "preview": preview.toggle()
        case "fullscreen": NSApp.keyWindow?.toggleFullScreen(nil)
        case "follow": followReading.toggle()
        case "previous": movePassage(by: -1)
        case "next": movePassage(by: 1)
        case "i": preview = false; NotificationCenter.default.post(name: .init("FocusInput"), object: nil)
        case "[": speed = max(0.5, speed - 0.25)
        case "]": speed = min(2, speed + 0.25)
        case "floating": toggleFloating()
        case "settings": if floating { toggleFloating() }; openSettings()
        case "open": openFile()
        default: break
        }
    }
}

struct WindowReader: NSViewRepresentable {
    let reader: Reader
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { reader.mainWindow = view.window; view.window?.titleVisibility = .hidden }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct VoiceSpeedControls: View {
    @ObservedObject var reader: Reader
    var body: some View {
        HStack(spacing: 4) {
            Picker("Speed", selection: $reader.speed) {
                ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in Text(String(format: "%.2f×", speed)).tag(speed) }
            }.labelsHidden().frame(width: 68).help("Playback speed")
                .padding(.horizontal, 3).padding(.vertical, 5).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Picker("Voice", selection: $reader.voice) {
                ForEach(reader.modelVoices) { voice in
                    Text("\(voice.name) · \(voice.detail)").tag(voice.id)
                }
                if reader.modelVoices.isEmpty { Text("Add reference voice in Settings").tag("") }
            }.labelsHidden().frame(minWidth: 100, idealWidth: 180, maxWidth: 230).help("Choose voice")
                .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }.controlSize(.small).fixedSize(horizontal: false, vertical: true)
    }
}

extension Reader {
    var estimatedDuration: Double { Double(wordCount) * 60 / (155 * speed) }
    var estimatedElapsed: Double {
        guard !chunks.isEmpty else { return 0 }
        if current >= chunks.count { return estimatedDuration }
        let words = chunks.prefix(current).joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).count
        return min(estimatedDuration, Double(words) * 60 / (155 * speed) + (player?.currentTime ?? 0) / speed)
    }
    func timeLabel(_ seconds: Double) -> String {
        let seconds = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct PlaybackProgressStyle: ProgressViewStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(colorScheme == .light ? 0.18 : 0.22))
                Capsule().fill(Color.primary.opacity(0.8))
                    .frame(width: geometry.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
            }
        }.frame(height: 5)
    }
}

struct PlaybackControls: View {
    @ObservedObject var reader: Reader
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 8) {
                    Text(reader.timeLabel(reader.estimatedElapsed))
                    ProgressView(value: reader.estimatedDuration > 0 ? reader.estimatedElapsed / reader.estimatedDuration : 0)
                        .progressViewStyle(PlaybackProgressStyle())
                    Text("~" + reader.timeLabel(max(0, reader.estimatedDuration - reader.estimatedElapsed)))
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary).help("Estimated elapsed time and time remaining")
            }
            HStack(spacing: 10) {
                HStack(spacing: 14) {
                Button { reader.movePassage(by: -1) } label: { Image(systemName: "backward.end.fill") }.disabled(!reader.active).help("Previous passage")
                Button(action: reader.togglePlayback) { Image(systemName: reader.active && !reader.paused ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(reader.active && !reader.paused ? "Pause" : "Play").help(reader.active && !reader.paused ? "Pause" : "Play")
                    .disabled(reader.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(action: reader.stop) { Image(systemName: "stop.fill") }.disabled(!reader.active).help("Stop")
                Button { reader.movePassage(by: 1) } label: { Image(systemName: "forward.end.fill") }.disabled(!reader.active).help("Next passage")
                }.padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                VoiceSpeedControls(reader: reader).padding(.horizontal, 8)
                Spacer(minLength: 0)
                Button(action: reader.toggleFloating) { Image(systemName: reader.floating ? "macwindow" : "pip.enter") }
                    .help(reader.floating ? "Return to main window (⌘T)" : "Floating player (⌘T)")
            }.buttonStyle(.borderless)
            Text(reader.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.padding(16)
    }
}

struct FloatingPlayer: View {
    @ObservedObject var reader: Reader
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(reader.filename).lineLimit(1).font(.headline)
                Spacer()
                Toggle(isOn: $reader.alwaysOnTop) { Image(systemName: "pin") }.toggleStyle(.button).help("Always on top")
            }.padding(.horizontal, 16).padding(.top, 12)
            PlaybackControls(reader: reader)
            if let error = reader.error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
        }.frame(minWidth: 408, minHeight: 170)
        .background(PlaybackShortcuts(reader: reader))
    }
}

final class PastingTextView: NSTextView {
    var willPaste: ((Bool) -> Void)?
    override func paste(_ sender: Any?) {
        willPaste?(selectedRange().length == string.utf16.count)
        super.paste(sender)
    }
}

struct InputEditor: NSViewRepresentable {
    @ObservedObject var reader: Reader
    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let text = PastingTextView(frame: .zero)
        text.isRichText = false; text.allowsUndo = true
        text.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        text.textColor = .labelColor; text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 10, height: 12)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = reader.markdown
        text.delegate = context.coordinator
        text.willPaste = { [weak reader] replacing in reader?.beginPaste(replacingDocument: replacing) }
        scroll.documentView = text
        context.coordinator.text = text
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(forName: .init("FocusInput"), object: nil, queue: .main) { [weak text] _ in
            guard let text else { return }; text.window?.makeFirstResponder(text)
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, text.string != reader.markdown else { return }
        text.string = reader.markdown
        text.undoManager?.removeAllActions()
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let reader: Reader
        weak var text: NSTextView?
        var focusObserver: NSObjectProtocol?
        init(reader: Reader) { self.reader = reader }
        func textDidChange(_ notification: Notification) { if let text { reader.markdown = text.string } }
        deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
    }
}

final class RecentRowState: ObservableObject { @Published var hovering = false }

struct RecentDocumentRow: View {
    @ObservedObject var reader: Reader
    let document: RecentDocument
    @StateObject private var row = RecentRowState()
    @FocusState private var editing: Bool
    var body: some View {
        HStack(spacing: 6) {
            if reader.renamingDocumentID == document.id {
                TextField("Name", text: $reader.renameText).textFieldStyle(.plain).focused($editing)
                    .onSubmit { reader.finishRename() }
                    .onExitCommand { reader.renamingDocumentID = nil }
                    .onAppear { editing = true }
                    .onChange(of: editing) { if !editing && reader.renamingDocumentID == document.id { reader.finishRename() } }
            } else {
                Button { reader.openRecent(document) } label: {
                    Label(document.title, systemImage: document.path == nil ? "text.alignleft" : "doc.text")
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).help(document.path ?? document.title)
                Button { reader.renameRecent(document) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).opacity(row.hovering ? 1 : 0).help("Rename document")
                Button { reader.removeRecent(document) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).opacity(row.hovering ? 1 : 0)
                    .help("Remove from recents").accessibilityLabel("Remove \(document.title) from recents")
            }
        }.padding(.horizontal, 8).padding(.vertical, 4).onHover { row.hovering = $0 }
    }
}

struct UpdateNotice: View {
    @ObservedObject var reader: Reader
    var compact = false
    var body: some View {
        Button { reader.openSettings("updates") } label: {
            Text(compact ? "Update\navailable" : "Update available")
                .font(.system(size: compact ? 9 : 11, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, compact ? 5 : 12).padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.accentColor.opacity(0.25)))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        }.buttonStyle(.plain)
            .help("\(reader.availableUpdateVersion) is available. Open Updates.")
            .accessibilityLabel("Update available. Open update settings.")
    }
}

struct ContentView: View {
    @ObservedObject var reader: Reader
    @FocusState private var inputFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            if !reader.focusDocument {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 30, height: 30)
                        Text("AudibleInk").font(.system(size: 24, weight: .semibold, design: .serif))
                    }
                    Button(action: reader.openFile) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.badge.plus").frame(width: 22, height: 22)
                            Text("Open Document")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button(action: reader.newDraft) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.pencil").frame(width: 22, height: 22)
                            Text("New Text")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Divider()
                    Text("RECENT DOCUMENTS").font(.caption2).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(reader.recentDocuments) { document in
                                RecentDocumentRow(reader: reader, document: document)
                            }
                            if reader.recentDocuments.isEmpty { Text("Documents and pasted text appear here.").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Spacer()
                    if reader.availableUpdateURL != nil {
                        UpdateNotice(reader: reader)
                    }
                    HStack {
                        Button { reader.openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                        Spacer()
                        Button(action: reader.quit) { Label("Quit", systemImage: "power") }.help("Quit AudibleInk")
                    }.buttonStyle(.plain)
                }.padding(18).frame(width: 225).background(Color(nsColor: .controlBackgroundColor))
                Divider()
            } else {
                VStack(spacing: 22) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 30, height: 30).help("AudibleInk")
                    Button(action: reader.openFile) { Image(systemName: "doc.badge.plus").frame(width: 30, height: 30) }.help("Open Document")
                    Button(action: reader.newDraft) { Image(systemName: "square.and.pencil").frame(width: 30, height: 30) }.help("New Text")
                    Spacer()
                    if reader.availableUpdateURL != nil {
                        UpdateNotice(reader: reader, compact: true)
                    }
                    Button { reader.openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
                    Button(action: reader.quit) { Image(systemName: "power") }.help("Quit AudibleInk").accessibilityLabel("Quit AudibleInk")
                }.buttonStyle(.plain).font(.system(size: 17)).padding(.vertical, 18).frame(width: 58)
                    .background(Color(nsColor: .controlBackgroundColor))
                Divider()
            }
            VStack(spacing: 12) {
                HStack {
                    Picker("Document", selection: $reader.preview) { Text("Input").tag(false); Text("Preview").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    Spacer()
                    if reader.importing { ProgressView().controlSize(.small) }
                    Text("\(reader.wordCount) words").font(.caption).foregroundStyle(.secondary)
                    Picker("Model", selection: $reader.selectedModel) {
                        ForEach(SpeechModel.all) { model in Text(model.name).tag(model.id) }
                    }.labelsHidden().frame(width: 165).help("Speech model")
                }
                if reader.preview { MarkdownPreview(reader: reader) }
                else { InputEditor(reader: reader) }
                if let error = reader.error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                PlaybackControls(reader: reader).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 12))
            }.padding(16)
        }.frame(minWidth: 800, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { reader.focusDocument.toggle() } label: { Image(systemName: "sidebar.left") }.help("Toggle sidebar")
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .principal) {
                    Text(reader.filename).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .center)
                }.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    Text(reader.filename).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .background(WindowReader(reader: reader))
        .background(PlaybackShortcuts(reader: reader))
        .onReceive(NotificationCenter.default.publisher(for: .init("FocusInput"))) { _ in inputFocused = true }
        .onChange(of: reader.speed) { reader.updatePlaybackSpeed() }
        .onChange(of: reader.selectedModel) { reader.selectModel() }
        .onChange(of: reader.voice) { UserDefaults.standard.set(reader.voice, forKey: "voice") }
        .onChange(of: reader.markdown) { if reader.active { reader.stop() }; reader.documentChanged() }
        .onChange(of: reader.includeCode) { reader.refreshPreview() }
        .onChange(of: reader.pronunciations) { UserDefaults.standard.set(reader.pronunciations, forKey: "pronunciations") }
        .onChange(of: reader.cacheLimitMB) { reader.updateCacheLimit() }
        .onChange(of: reader.privateAudio) { reader.updatePrivateAudio() }
        .sheet(isPresented: $reader.showSettings) { ReaderSettings(reader: reader) }
    }
}

struct ReaderSettings: View {
    @ObservedObject var reader: Reader
    private let sections = [("general", "General", "gearshape"), ("updates", "Updates", "arrow.down.circle"), ("cache", "Audio Cache", "internaldrive"), ("dictionary", "Dictionary", "character.book.closed"), ("shortcuts", "Keyboard Shortcuts", "keyboard"), ("tips", "Listening Tip", "info.circle")]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Settings").font(.title2).padding(.bottom, 16)
                    ForEach(sections, id: \.0) { section in
                        Button { reader.settingsTab = section.0 } label: {
                            Label(section.1, systemImage: section.2).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(reader.settingsTab == section.0 ? Color.accentColor.opacity(0.14) : .clear).clipShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).focusable(false)
                    }
                    Spacer()
                }.padding(18).frame(width: 205).background(.quaternary.opacity(0.3))
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    Text(sections.first(where: { $0.0 == reader.settingsTab })?.1 ?? "General").font(.title2)
                    settingsContent
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack { Spacer(); Button("Done") { reader.showSettings = false }.keyboardShortcut(.defaultAction) }.padding(14)
        }.frame(width: 790, height: 530)
    }
    @ViewBuilder private var settingsContent: some View {
        switch reader.settingsTab {
        case "cache":
            Picker("Maximum storage", selection: $reader.cacheLimitMB) {
                ForEach([100, 250, 500, 1024, 2048, 5120, 10240], id: \.self) { limit in Text(limit < 1024 ? "\(limit) MB" : "\(limit / 1024) GB").tag(limit) }
            }.disabled(reader.cacheBusy)
            HStack { Text("\(reader.cacheUsage) · \(reader.cacheFiles) passages"); Spacer(); Button("Clear Cache", action: reader.clearAudioCache).disabled(reader.cacheBusy) }
                .onAppear { reader.refreshCacheInfo() }
            Toggle("Private audio", isOn: $reader.privateAudio)
        case "dictionary":
            Text("One replacement per line: API = A P I").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $reader.pronunciations).font(.system(.body, design: .monospaced))
            Toggle("Technical pronunciation cleanup", isOn: $reader.technical)
        case "updates":
            HStack {
                Text("Version \(AppUpdates.installedVersion)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(reader.checkingForUpdates ? "Checking…" : "Check for Updates") { reader.checkForUpdates() }
                    .disabled(reader.checkingForUpdates)
            }
            Toggle("Check for updates at launch", isOn: $reader.checkUpdatesOnLaunch)
                .toggleStyle(.checkbox)
            Text(reader.updateMessage).font(.caption).foregroundStyle(.secondary)
            if reader.availableUpdateURL != nil {
                Button("Download \(reader.availableUpdateVersion) from GitHub", action: reader.openAvailableUpdate)
            }
        case "shortcuts": ShortcutEditor(reader: reader)
        case "tips":
            Text("For documents or notes with complex code blocks or diagrams, ask an LLM to create a TTS-friendly version for a better listening experience.")
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            Picker("Appearance", selection: $reader.uiMode) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            Toggle("Follow reading", isOn: $reader.followReading)
            Toggle("Read code blocks", isOn: $reader.includeCode)
            Toggle("Floating player always on top", isOn: $reader.alwaysOnTop)
            Divider()
            Text("Speech Models").font(.headline)
            Text("All models run locally with no per-use API charge. Downloads need internet; electricity and network charges may apply. RAM figures are planning estimates, vary with passage length, and exclude the rest of the app. Only one speech model is loaded at a time.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(SpeechModel.all) { model in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.name).fontWeight(.medium)
                        Spacer()
                        if let bytes = reader.modelBytes[model.id], bytes > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            Button("Delete Model", role: .destructive) { reader.deleteModel(model.id) }.disabled(reader.deletingModel)
                        } else { Text("Not downloaded").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(model.resources).font(.caption).foregroundStyle(.secondary)
                }
            }
            IndicReferenceSettings(reader: reader)
            Text(reader.modelMessage).font(.caption).foregroundStyle(.secondary)
                .onAppear { reader.refreshModelStorage() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

final class ReferenceVoiceEditor: ObservableObject {
    @Published var name = ""
    @Published var path = ""
    @Published var transcript = ""
}

struct IndicReferenceSettings: View {
    @ObservedObject var reader: Reader
    @StateObject private var editor = ReferenceVoiceEditor()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("IndicF5 reference voices").font(.headline)
            Text("Supports Hindi, Marathi, Tamil, Telugu, Kannada, Bengali, Gujarati, Malayalam, Odia, Punjabi and Assamese. Install with scripts/setup.sh, accept the IndicF5 access terms on Hugging Face, then run hf auth login in Terminal. Add a clean 5–10 second reference clip and its exact transcript; the speaker comes from this clip.").font(.caption).foregroundStyle(.secondary)
            Link("IndicF5 model access", destination: URL(string: "https://huggingface.co/ai4bharat/IndicF5")!)
            ForEach(reader.referenceVoices) { reference in
                HStack {
                    Text(reference.name)
                    Spacer()
                    Button("Remove Voice", role: .destructive) {
                        reader.referenceVoices.removeAll { $0.id == reference.id }
                        reader.saveReferenceVoices()
                    }
                }
            }
            TextField("Voice name", text: $editor.name)
            HStack {
                Button("Choose Reference Audio…") { if let selected = reader.chooseReferenceAudio() { editor.path = selected } }
                Text(editor.path.isEmpty ? "No clip selected" : URL(fileURLWithPath: editor.path).lastPathComponent).font(.caption).lineLimit(1)
            }
            TextField("Exact reference transcript", text: $editor.transcript)
            Button("Add Voice") {
                reader.referenceVoices.append(ReferenceVoice(name: editor.name.trimmingCharacters(in: .whitespacesAndNewlines), path: editor.path, transcript: editor.transcript))
                reader.saveReferenceVoices()
                editor.name = ""; editor.path = ""; editor.transcript = ""
            }.disabled(editor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editor.path.isEmpty || editor.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

final class ShortcutEditorState: ObservableObject {
    @Published var recording: String?
    @Published var message = "Click a shortcut and press the new key combination."
}

struct ShortcutEditor: View {
    @ObservedObject var reader: Reader
    @StateObject private var editor = ShortcutEditorState()
    var body: some View {
        VStack(alignment: .leading) {
            Text(editor.message).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                ForEach(reader.shortcuts) { binding in
                    HStack {
                        Text(binding.title)
                        Spacer()
                        Button(editor.recording == binding.id ? "Press keys…" : display(binding)) { editor.recording = binding.id }
                            .frame(width: 150)
                    }.padding(.vertical, 3)
                }
            }
            Button("Restore Defaults") { reader.shortcuts = ShortcutBinding.defaults; editor.recording = nil }
        }.padding().background(ShortcutRecorder(recording: $editor.recording) { key, flags in
            guard let id = editor.recording, let index = reader.shortcuts.firstIndex(where: { $0.id == id }) else { return }
            if reader.shortcuts.contains(where: { $0.id != id && $0.key == key && $0.modifiers == flags.rawValue }) {
                editor.message = "That shortcut is already assigned. Choose another combination."
            } else {
                reader.shortcuts[index].key = key; reader.shortcuts[index].modifiers = flags.rawValue
                editor.message = "Shortcut saved."
                editor.recording = nil
            }
        })
    }
    private func display(_ binding: ShortcutBinding) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: binding.modifiers)
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + binding.key.capitalized
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var recording: String?
    let save: (String, NSEvent.ModifierFlags) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { let view = NSView(); context.coordinator.view = view; return view }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.remove()
        guard recording != nil else { return }
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard view.window?.isKeyWindow == true, event.window === view.window, let key = event.charactersIgnoringModifiers, !event.isARepeat else { return event }
            save(ShortcutBinding.normalized(event.keyCode == 3 && event.modifierFlags.contains(.option) ? "f" : key), event.modifierFlags.intersection([.command, .control, .option, .shift]))
            return nil
        }
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { remove() }
    }
}

struct PlaybackShortcuts: NSViewRepresentable {
    let reader: Reader
    static func command(for key: String, modifiers: NSEvent.ModifierFlags, editing: Bool, bindings: [ShortcutBinding] = ShortcutBinding.defaults) -> String? {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        let normalized = ShortcutBinding.normalized(key)
        if let match = bindings.first(where: { $0.key == normalized && $0.modifiers == flags.rawValue }) {
            return editing && flags.isEmpty && match.id != "escape" ? nil : match.id
        }
        // Retain familiar aliases unless their action has been customized.
        if flags == .command {
            let aliases = ["return": " ", "i": "i", "[": "[", "]": "]"]
            if let action = aliases[normalized], let original = ShortcutBinding.defaults.first(where: { $0.id == action }),
               bindings.contains(where: { $0.id == action && $0.key == original.key && $0.modifiers == original.modifiers }) { return action }
        }
        return nil
    }
    func makeCoordinator() -> Coordinator { Coordinator(reader: reader) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); context.coordinator.view = view; context.coordinator.install(); return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator {
        weak var view: NSView?
        let reader: Reader
        var monitor: Any?
        init(reader: Reader) { self.reader = reader }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, window.isKeyWindow, window.attachedSheet == nil, event.window === window,
                      let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
                let editing = (window.firstResponder as? NSTextView)?.isEditable == true || (window.firstResponder as? NSTextField)?.isEditable == true
                guard let command = PlaybackShortcuts.command(for: event.keyCode == 3 && event.modifierFlags.contains(.option) ? "f" : key, modifiers: event.modifierFlags, editing: editing, bindings: self.reader.shortcuts) else { return event }
                if !event.isARepeat { self.reader.perform(command) }
                return nil
            }
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { remove() }
    }
}

@main struct MarkdownVoiceApp: App {
    @StateObject private var reader = Reader()
    var body: some Scene {
        WindowGroup("AudibleInk") {
            ContentView(reader: reader)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in reader.shutdown() }
        }.defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Open Document…", action: reader.openFile) }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { reader.perform("settings") } }
            CommandMenu("Playback") {
                Button("Play / Pause", action: reader.togglePlayback)
                Button("Stop", action: reader.stop)
                Picker("Voice", selection: $reader.voice) { ForEach(reader.modelVoices) { voice in Text("\(voice.name) · \(voice.detail)").tag(voice.id) } }
                Menu("Speed") { Picker("Speed", selection: $reader.speed) { ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in Text(String(format: "%.2f×", speed)).tag(speed) } } }
            }
            CommandGroup(after: .sidebar) {
                Button(reader.floating ? "Show Main Window" : "Show Floating Player", action: reader.toggleFloating)
                Toggle("Floating Player Always on Top", isOn: $reader.alwaysOnTop)
            }
            CommandGroup(replacing: .help) { Button("Keyboard Shortcuts…") { reader.perform("settings"); reader.settingsTab = "shortcuts" } }
        }
    }
}
