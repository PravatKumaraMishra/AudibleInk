import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import PDFKit

struct Voice: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
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

final class Reader: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var markdown = "# A little space to listen\n\nPaste your Markdown here, or open a file. Turn your notes, articles, and ideas into a voice you can take your time with.\n\n## Made for your Mac\n\nListen with Heart or choose another Kokoro voice for local neural speech.\n\n- Your words stay on this machine.\n- Links and formatting become clean, readable speech.\n- Code blocks are skipped unless you include them."
    @Published var voice = ""
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
    @Published var followReading = true
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
    @Published var filename = "Untitled.md"
    @Published var error: String?
    let voices: [Voice]
    private var idleWork: DispatchWorkItem?
    private let idleTimeout: TimeInterval = 60
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    private var activityMonitor: Any?
    private let audioDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-audio-\(UUID().uuidString)", isDirectory: true)
    private var player: AVAudioPlayer?
    private var queuedCacheFiles: [URL: URL] = [:]
    private var playingCacheFile: URL?
    private var process: Process?
    private var input: FileHandle?
    private let writer = DispatchQueue(label: "murmur.worker-input")
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
        voices = list
        super.init()
        voice = "kokoro:af_heart"
        let savedLimit = UserDefaults.standard.integer(forKey: "audioCacheLimitMB")
        if [100, 250, 500, 1024, 2048, 5120, 10240].contains(savedLimit) { cacheLimitMB = savedLimit }
        privateAudio = UserDefaults.standard.bool(forKey: "privateAudio")
        if let saved = UserDefaults.standard.string(forKey: "document") { markdown = saved }
        if let saved = UserDefaults.standard.string(forKey: "pronunciations") { pronunciations = saved }
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.userDidInteract()
            return event
        }
        refreshPreview()
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
        let python = root?.appendingPathComponent(".venv/bin/python") ?? URL(fileURLWithPath: configuredPath ?? "")
        let worker = root?.appendingPathComponent("backend/worker.py") ?? resources.appendingPathComponent("worker.py")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw NSError(domain: "Reader", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Python runtime is missing. Run scripts/setup.sh, then scripts/build.sh."])
        }
        let workerDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workerDirectory, withIntermediateDirectories: true)
        let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = python
        task.arguments = ["-u", worker.path]
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = workerDirectory.path
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["HF_HUB_DISABLE_XET"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
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
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = message["id"] as? String else { continue }
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
        stop()
        error = nil; active = true; paused = initiallyPaused; status = "Preparing your Markdown…"
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
            self.followReading = true
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
        request(["command": "synth", "text": speechChunks[index], "voice": String(selectedVoice.split(separator: ":", maxSplits: 1)[1]), "engine": "kokoro", "speed": 1.0, "private": sessionPrivateAudio]) { [weak self] response in
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
                let directory = ProcessInfo.processInfo.environment["MURMUR_AUDIO_CACHE"]
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
    private func fail(_ message: String) { cacheBusy = false; stop(); error = message; status = "Something needs attention" }
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
        importing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DocumentImport.text(from: url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.importing = false
                switch result {
                case .success(let text): self.stop(); self.markdown = text; self.filename = url.lastPathComponent
                case .failure(let error): self.error = "Could not import document: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var reader: Reader
    @FocusState private var inputFocused: Bool
    private let ink = Color(red: 0.16, green: 0.23, blue: 0.21)
    private let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    var body: some View {
        HStack(spacing: 0) {
            if !reader.focusDocument {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill").font(.system(size: 34)).foregroundStyle(ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("murmur").font(.system(size: 25, weight: .semibold, design: .serif))
                        Text("MARKDOWN, OUT LOUD").font(.system(size: 8, weight: .semibold)).tracking(2)
                    }
                }.padding(.bottom, 14)
                Text("YOUR STUDIO").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                Label("Reading room", systemImage: "book.closed").font(.system(size: 14, weight: .medium))
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(ink.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 9))
                Button(action: reader.openFile) { Label("Open Document", systemImage: "plus") }.buttonStyle(.plain).keyboardShortcut("o")
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("THE VOICE").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    Picker("Voice", selection: $reader.voice) {
                        ForEach(reader.voices) { voice in Text("\(voice.name) · \(voice.detail)").tag(voice.id) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Pace"); Spacer(); Text(String(format: "%.2f×", reader.speed)).monospacedDigit() }.font(.system(size: 12))
                    Slider(value: $reader.speed, in: 0.5...2.0, step: 0.25).tint(ink)
                    HStack { Text("Unhurried"); Spacer(); Text("Brisk") }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Toggle("Read code blocks", isOn: $reader.includeCode).font(.system(size: 12)).toggleStyle(.checkbox)
                Button("Pronunciation dictionary…") { reader.showPronunciations = true }.buttonStyle(.plain).font(.system(size: 12))
                Button("Audio cache…") {
                    reader.showCacheSettings = true
                    reader.refreshCacheInfo()
                }.buttonStyle(.plain).font(.system(size: 12))
                if reader.privateAudio { Label("Private audio", systemImage: "lock").font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
            }.padding(18).frame(width: 245).background(paper)
            Rectangle().fill(ink.opacity(0.1)).frame(width: 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(reader.filename, systemImage: "doc.text").font(.system(size: 12)).foregroundStyle(ink.opacity(0.85))
                    listeningTipButton
                    if reader.importing {
                        Text("Importing document…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { reader.focusDocument.toggle() } label: {
                        Image(systemName: reader.focusDocument ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(.plain).help(reader.focusDocument ? "Show voice controls" : "Expand document")
                    Text("LOCAL AUDIO").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(ink)
                    Circle().fill(Color.green.opacity(0.7)).frame(width: 6, height: 6)
                }.padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                HStack(spacing: 8) {
                    ForEach([false, true], id: \.self) { preview in
                        Button {
                            reader.preview = preview
                            inputFocused = false
                        } label: {
                            Text(preview ? "Preview" : "Input")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(reader.preview == preview ? Color.white : ink)
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .background(reader.preview == preview ? ink : ink.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(.horizontal, 18).padding(.vertical, 10)
                ZStack(alignment: .topLeading) {
                    if reader.preview {
                        MarkdownPreview(reader: reader)
                    } else {
                        TextEditor(text: $reader.markdown).font(.system(size: 14, design: .monospaced)).lineSpacing(7).scrollContentBackground(.hidden).padding(10).focused($inputFocused)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.75)).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink.opacity(0.1))).padding(.horizontal, 18)
                HStack { if reader.preview { Toggle("Follow reading", isOn: $reader.followReading).toggleStyle(.checkbox) }; Spacer(); Text("\(reader.wordCount) words · ~\(max(1, Int(Double(reader.wordCount) / (155 * reader.speed)))) min") }
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
                if let error = reader.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 18).padding(.bottom, 12)
                }
                VStack(alignment: .leading, spacing: 14) {
                    ProgressView(value: reader.progress).tint(ink)
                    HStack(spacing: 14) {
                        Button(action: reader.togglePlayback) {
                            Label(reader.active ? (reader.paused ? "Resume" : "Pause") : "Start listening", systemImage: reader.active && !reader.paused ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .medium)).padding(.horizontal, 18).padding(.vertical, 12)
                                .background(ink).foregroundStyle(.white).clipShape(Capsule())
                        }.buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(reader.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if reader.active { Button(action: reader.stop) { Image(systemName: "stop.fill") }.buttonStyle(.plain).help("Stop reading") }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reader.status).font(.system(size: 11, weight: .medium))
                            if !reader.chunks.isEmpty { Text("Passage \(min(reader.current + 1, reader.chunks.count)) of \(reader.chunks.count)").font(.system(size: 10)).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Image(systemName: "waveform").font(.system(size: 26)).foregroundStyle(ink.opacity(0.45))
                    }
                }.padding(16).background(paper).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 18).padding(.bottom, 16)
            }.background(Color(red: 0.99, green: 0.985, blue: 0.97))
        }.foregroundStyle(ink).preferredColorScheme(.light).frame(minWidth: 960, minHeight: 700)
        .background(PlaybackShortcuts { key in
            switch key {
            case " ": reader.togglePlayback()
            case "s": reader.stop()
            case "startStop": reader.toggleStartStop()
            case "escape":
                inputFocused = false
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            case "preview":
                inputFocused = false
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
                reader.preview.toggle()
            case "fullscreen": NSApp.keyWindow?.toggleFullScreen(nil)
            case "follow": reader.followReading.toggle()
            case "previous": reader.movePassage(by: -1)
            case "next": reader.movePassage(by: 1)
            case "i":
                reader.preview = false
                DispatchQueue.main.async { inputFocused = true }
            case "[": reader.speed = max(0.5, reader.speed - 0.25)
            case "]": reader.speed = min(2.0, reader.speed + 0.25)
            default: return
            }
        })
        .onChange(of: reader.speed) { reader.updatePlaybackSpeed() }
        .onChange(of: reader.markdown) {
            if reader.active { reader.stop() }
            reader.documentChanged()
        }
        .onChange(of: reader.includeCode) { reader.refreshPreview() }
        .onChange(of: reader.pronunciations) { UserDefaults.standard.set(reader.pronunciations, forKey: "pronunciations") }
        .onChange(of: reader.cacheLimitMB) { reader.updateCacheLimit() }
        .onChange(of: reader.privateAudio) { reader.updatePrivateAudio() }
        .sheet(isPresented: $reader.showCacheSettings) { cacheSettings }
        .sheet(isPresented: $reader.showShortcuts) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Keyboard Shortcuts").font(.system(size: 24, design: .serif))
                Grid(alignment: .leading, horizontalSpacing: 48, verticalSpacing: 14) {
                    shortcutRow("Start / Pause / Resume", "Space / ⌘ Return")
                    shortcutRow("Start / Stop playback", "⌘ S")
                    shortcutRow("Stop playback", "S")
                    shortcutRow("Focus input", "I / ⌘ I")
                    shortcutRow("Leave input", "Esc")
                    shortcutRow("Decrease pace by 0.25×", "[ / ⌘ [")
                    shortcutRow("Increase pace by 0.25×", "] / ⌘ ]")
                    shortcutRow("Toggle Input / Preview", "⌘ P")
                    shortcutRow("Toggle Follow reading", "⌘ F")
                    shortcutRow("Toggle full screen", "⌥ F")
                    shortcutRow("Previous / Next passage", "⌘ ← / ⌘ →")
                    shortcutRow("Open Document", "⌘ O")
                }
                Text("Single-key shortcuts are inactive while typing. Pace ranges from 0.5× to 2×.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { reader.showShortcuts = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 550)
        }
        .sheet(isPresented: $reader.showPronunciations) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Say it your way").font(.system(size: 25, design: .serif))
                TextEditor(text: $reader.pronunciations).font(.system(size: 13, design: .monospaced)).frame(height: 290).border(Color.gray.opacity(0.3))
                Toggle("Separate camelCase words and speak common operators", isOn: $reader.technical)
                HStack { Spacer(); Button("Done") { reader.showPronunciations = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 570)
        }
    }
    private var cacheSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Audio cache").font(.system(size: 25, design: .serif))
            Text("Reuse saved passages without generating speech again. There is no time limit; the least recently played audio is removed when storage fills up.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("Maximum storage", selection: $reader.cacheLimitMB) {
                Text("100 MB").tag(100)
                Text("250 MB").tag(250)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1024)
                Text("2 GB").tag(2048)
                Text("5 GB").tag(5120)
                Text("10 GB").tag(10240)
            }.disabled(reader.cacheBusy)
            HStack {
                Text("\(reader.cacheUsage) used · \(reader.cacheFiles) saved passages")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if reader.cacheBusy { ProgressView().controlSize(.small) }
                Button("Clear Cache", action: reader.clearAudioCache).disabled(reader.cacheBusy)
            }
            Text("Changing the limit applies immediately. Clear Cache stops reading and removes saved passage audio. Downloaded models are kept.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Toggle("Private audio — don’t read or save cached speech", isOn: $reader.privateAudio)
                .font(.system(size: 12))
            Text("Changing private audio stops reading. Existing cached audio stays until cleared. Your draft and pronunciation dictionary are still saved normally.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { reader.showCacheSettings = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 540)
    }

    private var listeningTipButton: some View {
                    Button { reader.showListeningTip.toggle() } label: {
                        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Listening tip")
                    .help("Listening tip")
                    .popover(isPresented: $reader.showListeningTip) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Listening tip").font(.headline)
                            Text("For complex notes with code or diagrams, ask an LLM for a TTS-friendly version for a better listening experience.")
                                .font(.system(size: 12))
                            Text("You can find keyboard shortcuts in the Help menu.")
                                .font(.system(size: 12))
                        }.padding(16).frame(width: 290)
                    }
    }

    private func shortcutRow(_ title: String, _ keys: String) -> some View {
        GridRow {
            Text(title).font(.system(size: 13))
            Text(keys).font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.black.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct PlaybackShortcuts: NSViewRepresentable {
    static func command(for key: String, modifiers: NSEvent.ModifierFlags, editing: Bool) -> String? {
        let modifiers = modifiers.intersection([.command, .control, .option, .shift])
        if modifiers == .option, key == "f" { return "fullscreen" }
        if modifiers == .command {
            switch key {
            case "s": return "startStop"
            case "i", "[", "]": return key
            case "p": return "preview"
            case "f": return "follow"
            case "\u{f702}": return "previous"
            case "\u{f703}": return "next"
            case "\r": return " "
            default: return nil
            }
        }
        guard modifiers.isEmpty else { return nil }
        if key == "\u{1b}" { return "escape" }
        guard !editing, [" ", "s", "i", "[", "]"].contains(key) else { return nil }
        return key
    }

    let action: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.action = action }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        weak var view: NSView?
        var action: (String) -> Void
        private var monitor: Any?
        init(action: @escaping (String) -> Void) { self.action = action }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window,
                      window.isKeyWindow, window.attachedSheet == nil,
                      event.window === window,
                      let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
                let editing = (window.firstResponder as? NSTextView)?.isEditable == true
                    || (window.firstResponder as? NSTextField)?.isEditable == true
                guard let command = PlaybackShortcuts.command(for: event.keyCode == 3 && event.modifierFlags.contains(.option) ? "f" : key, modifiers: event.modifierFlags, editing: editing) else { return event }
                if !event.isARepeat { self.action(command) }
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
        WindowGroup("Murmur — Markdown to Speech") {
            ContentView(reader: reader)
                .onAppear {
                    if let url = Bundle.main.url(forResource: "Murmur", withExtension: "icns"),
                       let icon = NSImage(contentsOf: url) {
                        NSApplication.shared.applicationIconImage = icon
                        NSApplication.shared.dockTile.display()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in reader.shutdown() }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Document…", action: reader.openFile).keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts…") { reader.showShortcuts = true }
            }
        }
    }
}
