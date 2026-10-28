"""Verify draft history and renaming with isolated preferences."""
from pathlib import Path
import subprocess
import tempfile
import os
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/MarkdownVoice.swift').read_text().split('@main struct MarkdownVoiceApp:')[0]
source = source.replace('UserDefaults.standard', 'draftTestDefaults')
source += r'''
let draftTestSuite = "audibleink-drafts-\(UUID().uuidString)"
let draftTestDefaults = UserDefaults(suiteName: draftTestSuite)!
@main struct DraftCheck {
    static func main() {
        defer { draftTestDefaults.removePersistentDomain(forName: draftTestSuite) }
        let reader = Reader()
        defer { reader.shutdown() }
        precondition(reader.recentDocuments.isEmpty)
        precondition(reader.referenceVoices.isEmpty)
        reader.markdown = "First pasted document"
        reader.documentChanged()
        precondition(reader.recentDocuments.count == 1)
        let first = reader.recentDocuments[0]
        precondition(first.title == "Untitled 1")
        reader.markdown += " edited"
        reader.documentChanged()
        precondition(reader.recentDocuments.count == 1)
        reader.beginPaste(replacingDocument: true)
        reader.markdown = "Second pasted document"
        reader.documentChanged()
        precondition(reader.recentDocuments.count == 2)
        precondition(reader.filename == "Untitled 2")
        reader.renameRecent(reader.recentDocuments[0])
        reader.renameText = "My notes"
        reader.finishRename()
        precondition(reader.filename == "My notes")
        let persisted = try! JSONDecoder().decode([RecentDocument].self, from: draftTestDefaults.data(forKey: "recentDocuments")!)
        precondition(persisted[0].title == "My notes")
        precondition(persisted[1].text == "First pasted document edited")
        reader.openRecent(first)
        // Reopening uses the latest saved snapshot, passed by the sidebar.
        reader.openRecent(persisted[1])
        precondition(reader.markdown == "First pasted document edited")
        precondition(reader.timeLabel(125) == "2:05")
        let imported = RecentDocument(id: "imported", title: "Original file", path: "/tmp/keep-original.md")
        reader.recentDocuments.append(imported)
        reader.removeRecent(imported)
        precondition(!reader.recentDocuments.contains { $0.id == imported.id })
        let current = reader.recentDocuments.first { $0.text == reader.markdown }!
        reader.removeRecent(current)
        precondition(reader.markdown.isEmpty)
        precondition(!reader.recentDocuments.contains { $0.id == current.id })
        precondition(draftTestDefaults.string(forKey: "document") == nil)
        let remaining = try! JSONDecoder().decode([RecentDocument].self, from: draftTestDefaults.data(forKey: "recentDocuments")!)
        precondition(!remaining.contains { $0.id == current.id })
        print("PASS: remove recent imports and active drafts; numbered pasted drafts, updates, rename, persistence, reopen, time formatting")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='audibleink-drafts-') as temp:
    swift = Path(temp) / 'DraftCheck.swift'
    binary = Path(temp) / 'DraftCheck'
    swift.write_text(source)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(root / '.cache/clang'), str(swift), str(root / 'Sources/MarkdownPreview.swift'), '-o', str(binary), '-framework', 'SwiftUI', '-framework', 'AppKit', '-framework', 'AVFoundation', '-framework', 'WebKit', '-framework', 'PDFKit'], check=True)
    subprocess.run([str(binary)], env={**os.environ, 'MARKDOWN_VOICE_ROOT': str(root)}, check=True, timeout=20)
