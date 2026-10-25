import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct Voice: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    var neural: Bool { (id.hasPrefix("kokoro:") || id.hasPrefix("qwen:")) }
}

final class Reader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var markdown = "# A little space to listen\n\nPaste your Markdown here, or open a file. Turn your notes, articles, and ideas into a voice you can take your time with.\n\n## Made for your Mac\n\nChoose English (India) for a familiar voice, or try Kokoro for local neural speech.\n\n- Your words stay on this machine.\n- Links and formatting become clean, readable speech.\n- Code blocks are skipped unless you include them."
    @Published var voice = ""
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
    @Published var technical = true
    @Published var pronunciations = "API = A P I\nREST = rest\nJSON = jay son\nSQL = sequel\nJPA = J P A\nJVM = J V M\nHTTP = H T T P\nHTTPS = H T T P S\nURI = U R I\nURL = U R L\nCRUD = crud\nDTO = D T O\nDAO = D A O\nHATEOAS = hate ee oss\nOAuth = oh auth\nPostgreSQL = post gress Q L\nMySQL = my sequel\n@GetMapping = get mapping\n@RestController = rest controller"
    private var speechChunks: [String] = []
    private var previewRevision = UUID()
    private var refreshWork: DispatchWorkItem?
    @Published var filename = "Untitled.md"
    @Published var error: String?
    let voices: [Voice]
    private let speech = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
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
    private var selectedSpeed = 1.0
    private var diagnostics = ""
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let indian = installed.filter { $0.language.replacingOccurrences(of: "_", with: "-").lowercased() == "en-in" }
            .sorted { $0.name < $1.name }
        var list = indian.map { Voice(id: $0.identifier, name: $0.name, detail: "English (India) · macOS") }
        if list.isEmpty, let english = installed.first(where: { $0.language.hasPrefix("en") }) {
            list.append(Voice(id: english.identifier, name: english.name, detail: "English · macOS"))
        }
        list += [Voice(id: "kokoro:af_heart", name: "Heart", detail: "American · Kokoro"),
                 Voice(id: "kokoro:af_bella", name: "Bella", detail: "American · Kokoro"),
                 Voice(id: "kokoro:am_michael", name: "Michael", detail: "American · Kokoro"),
                 Voice(id: "kokoro:bf_emma", name: "Emma", detail: "British · Kokoro"),
                 Voice(id: "kokoro:bm_george", name: "George", detail: "British · Kokoro")]
        list += [Voice(id: "qwen:Ryan", name: "Ryan", detail: "English · Qwen3 0.6B · 8-bit"),
                 Voice(id: "qwen:Aiden", name: "Aiden", detail: "English · Qwen3 0.6B · 8-bit"),
                 Voice(id: "qwen:Vivian", name: "Vivian", detail: "English · Qwen3 0.6B · 8-bit")]
        voices = list
        super.init()
        voice = "qwen:Ryan"
        speech.delegate = self
        if let saved = UserDefaults.standard.string(forKey: "document") { markdown = saved }
        if let saved = UserDefaults.standard.string(forKey: "pronunciations") { pronunciations = saved }
        refreshPreview()

    }

    var wordCount: Int { markdown.split(whereSeparator: { $0.isWhitespace }).count }
    var isNeural: Bool { voice.hasPrefix("kokoro:") || voice.hasPrefix("qwen:") }
    private var selectedNeural: Bool { selectedVoice.hasPrefix("kokoro:") || selectedVoice.hasPrefix("qwen:") }
    private var engineLabel: String { selectedVoice.hasPrefix("qwen:") ? "Qwen3 0.6B · 8-bit" : "Kokoro" }
    var voiceDescription: String {
        if voice.hasPrefix("qwen:") { return "Qwen3-TTS · 0.6B · 8-bit\nMLX on your Mac · larger model" }
        if isNeural { return "Kokoro · 82M parameters\nMLX acceleration on your Mac" }
        return "English (India) & installed voices\nApple’s on-device speech engine"
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
        let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = python
        task.arguments = ["-u", worker.path]
        var env = ProcessInfo.processInfo.environment
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["HF_HUB_DISABLE_XET"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["HF_HOME"] = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MarkdownVoice/huggingface").path
        task.environment = env
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                self?.diagnostics = String((self?.diagnostics ?? "").suffix(2000)) + (String(data: data, encoding: .utf8) ?? "")
            }
        }
        task.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                guard let self, self.process === task else { return }
                self.process = nil; self.callbacks.removeAll(); self.buffer.removeAll()
                if self.active { self.fail("Speech worker stopped. \(self.diagnostics.suffix(700))") }
            }
        }
        try task.run()
        process = task; input = stdin.fileHandleForWriting
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = message["id"] as? String else { continue }
            callbacks.removeValue(forKey: id)?(message)
        }
    }

    private func request(_ payload: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        do {
            try launchWorker()
            let id = UUID().uuidString
            var object = payload; object["id"] = id
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
        UserDefaults.standard.set(markdown, forKey: "document")
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshPreview() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func refreshPreview() {
        let revision = UUID(); previewRevision = revision
        request(["command": "prepare", "text": markdown, "include_code": includeCode]) { [weak self] response in
            guard let self, self.previewRevision == revision else { return }
            if let html = response["html"] as? String { self.previewHTML = html }
            else if let error = response["error"] as? String { self.error = error }
        }
    }

    func start(at index: Int = 0) {
        stop()
        error = nil; active = true; status = "Preparing your Markdown…"
        selectedVoice = voice; selectedSpeed = speed
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
            if self.selectedNeural { self.fillQueue() } else { self.speakSystem() }
        }
    }

    private func speakSystem() {
        guard active, !paused, current < chunks.count else { return }
        let utterance = AVSpeechUtterance(string: speechChunks[current])
        utterance.voice = AVSpeechSynthesisVoice(identifier: selectedVoice)
        utterance.rate = Float(selectedSpeed) * AVSpeechUtteranceDefaultSpeechRate
        status = "Reading · \(utterance.voice?.language ?? "English")"
        currentUtterance = utterance
        speech.speak(utterance)
    }

    private func fillQueue() {
        guard active, !generating, queue.isEmpty, nextIndex < chunks.count else { return }
        generating = true
        let index = nextIndex; nextIndex += 1
        let session = generation
        if player == nil { status = "Generating speech… First use may download the model." }
        request(["command": "synth", "text": speechChunks[index], "voice": String(selectedVoice.split(separator: ":", maxSplits: 1)[1]), "engine": selectedVoice.hasPrefix("qwen:") ? "qwen" : "kokoro", "speed": selectedSpeed]) { [weak self] response in
            guard let self else { return }
            guard self.generation == session else {
                if let path = response["path"] as? String { try? FileManager.default.removeItem(atPath: path) }
                return
            }
            self.generating = false
            if let error = response["error"] as? String { self.fail(error); return }
            guard let path = response["path"] as? String else { self.fail("No audio received from the model."); return }
            self.queue.append((index, URL(fileURLWithPath: path)))
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
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            audio.delegate = self
            if selectedVoice.hasPrefix("qwen:") { audio.enableRate = true; audio.rate = Float(selectedSpeed) }
            player = audio; current = index
            guard audio.play() else { throw NSError(domain: "Reader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio playback could not start."]) }
            status = "Reading · \(engineLabel) on Apple Silicon"
            fillQueue()
        } catch { fail(error.localizedDescription) }
    }

    func togglePause() {
        guard active else { return }
        paused.toggle()
        if paused {
            player?.pause(); speech.pauseSpeaking(at: .immediate); status = "Paused"
        } else if selectedNeural {
            if let player { player.play(); status = "Reading · \(engineLabel) on Apple Silicon" } else { playNext() }
        } else {
            if speech.isPaused { speech.continueSpeaking(); status = "Reading" } else { speakSystem() }
        }
    }

    func stop() {
        generation = UUID(); active = false; paused = false
        currentUtterance = nil
        speech.stopSpeaking(at: .immediate); player?.stop(); player = nil
        for (_, url) in queue { try? FileManager.default.removeItem(at: url) }
        queue.removeAll(); generating = false; nextIndex = 0; current = 0; chunks = []
        status = "Ready when you are"
    }
    private func finish() { active = false; paused = false; current = chunks.count; status = "Finished. A little more clarity." }
    private func fail(_ message: String) { stop(); error = message; status = "Something needs attention" }
    func shutdown() { stop(); process?.terminate() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard active, currentUtterance === utterance, !selectedNeural else { return }
        currentUtterance = nil
        current += 1
        if current == chunks.count { finish() } else { speakSystem() }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        self.player = nil
        if flag { playNext() } else { fail("Audio playback was interrupted. Try reading again.") }
    }
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let text = try String(contentsOf: url, encoding: .utf8); stop(); markdown = text; filename = url.lastPathComponent }
        catch { self.error = "Could not open this file as UTF-8 text: \(error.localizedDescription)" }
    }
}

struct ContentView: View {
    @ObservedObject var reader: Reader
    private let ink = Color(red: 0.16, green: 0.23, blue: 0.21)
    private let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 25) {
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
                Button(action: reader.openFile) { Label("Open Markdown", systemImage: "plus") }.buttonStyle(.plain).keyboardShortcut("o")
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("THE VOICE").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    Picker("Voice", selection: $reader.voice) {
                        ForEach(reader.voices) { voice in Text("\(voice.name) · \(voice.detail)").tag(voice.id) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                    Text(reader.voiceDescription)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Pace"); Spacer(); Text(String(format: "%.1f×", reader.speed)).monospacedDigit() }.font(.system(size: 12))
                    Slider(value: $reader.speed, in: 0.6...1.6, step: 0.1).tint(ink)
                    HStack { Text("Unhurried"); Spacer(); Text("Brisk") }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Toggle("Read code blocks", isOn: $reader.includeCode).font(.system(size: 12)).toggleStyle(.checkbox)
                Button("Pronunciation dictionary…") { reader.showPronunciations = true }.buttonStyle(.plain).font(.system(size: 12))
                Text("Voice, pace, and code settings apply to your next reading.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Entirely on your Mac", systemImage: "lock.shield").font(.system(size: 12, weight: .medium))
                    Text("No account. No text sent to a server. Neural models download on first use.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                }
            }.padding(25).frame(width: 265).background(paper)
            Rectangle().fill(ink.opacity(0.1)).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label(reader.filename, systemImage: "doc.text").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("LOCAL AUDIO").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(ink)
                    Circle().fill(Color.green.opacity(0.7)).frame(width: 6, height: 6)
                }.padding(.horizontal, 36).padding(.vertical, 23)
                Divider()
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Give your words a voice.").font(.system(size: 31, weight: .regular, design: .serif))
                        Text("A quiet place to read with your ears.").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("View", selection: $reader.preview) { Text("Write").tag(false); Text("Preview").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }.padding(36)
                ZStack(alignment: .topLeading) {
                    if reader.preview {
                        MarkdownPreview(reader: reader)
                    } else {
                        TextEditor(text: $reader.markdown).font(.system(size: 14, design: .monospaced)).lineSpacing(7).scrollContentBackground(.hidden).padding(18).disabled(reader.active)
                    }
                }.background(Color.white.opacity(0.75)).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(ink.opacity(0.1))).padding(.horizontal, 36)
                HStack { if reader.preview { Toggle("Follow reading", isOn: $reader.followReading).toggleStyle(.checkbox) } else { Text("Markdown formatting is cleaned before reading.") }; Spacer(); Text("\(reader.wordCount) words · ~\(max(1, Int(Double(reader.wordCount) / (155 * reader.speed)))) min") }
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 36).padding(.vertical, 14)
                if let error = reader.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 36).padding(.bottom, 12)
                }
                VStack(alignment: .leading, spacing: 14) {
                    if reader.active, reader.current < reader.chunks.count {
                        Text(reader.chunks[reader.current]).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    ProgressView(value: reader.progress).tint(ink)
                    HStack(spacing: 14) {
                        Button(action: { reader.active ? reader.togglePause() : reader.start() }) {
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
                }.padding(24).background(paper).clipShape(RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 36).padding(.bottom, 28)
            }.background(Color(red: 0.99, green: 0.985, blue: 0.97))
        }.foregroundStyle(ink).frame(minWidth: 960, minHeight: 700)
        .onChange(of: reader.markdown) { reader.documentChanged() }
        .onChange(of: reader.includeCode) { reader.refreshPreview() }
        .onChange(of: reader.pronunciations) { UserDefaults.standard.set(reader.pronunciations, forKey: "pronunciations") }
        .sheet(isPresented: $reader.showPronunciations) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Say it your way").font(.system(size: 25, design: .serif))
                Text("One rule per line: term = how it should sound. Matches are case-sensitive and apply to whole terms. Your preview keeps the original text.").font(.system(size: 13)).foregroundStyle(.secondary)
                TextEditor(text: $reader.pronunciations).font(.system(size: 13, design: .monospaced)).frame(height: 290).border(Color.gray.opacity(0.3))
                Toggle("Separate camelCase words and speak common operators", isOn: $reader.technical)
                Text("Try API = A P I, JSON = jay son, or a phonetic spelling for an unfamiliar name. Rules apply on your next reading, in both engines.").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { reader.showPronunciations = false }.keyboardShortcut(.defaultAction) }
            }.padding(28).frame(width: 570)
        }
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
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1120, height: 780)
        .commands { CommandGroup(replacing: .newItem) { Button("Open Markdown…", action: reader.openFile).keyboardShortcut("o") } }
    }
}
