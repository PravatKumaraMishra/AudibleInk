"""Exercise native document extraction with generated local fixtures."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/MarkdownVoice.swift').read_text()
extractor = source[source.index('enum DocumentImport {'):source.index('final class Reader:')]
harness = r'''
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let prose = "Hello *listener*. A document with readable text."
for (ext, type) in [("docx", NSAttributedString.DocumentType.officeOpenXML), ("doc", .docFormat), ("rtf", .rtf)] {
    let url = directory.appendingPathComponent("sample.\(ext)")
    let attributed = NSAttributedString(string: prose)
    try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: type]).write(to: url)
    let imported = try DocumentImport.text(from: url)
    precondition(imported.contains("Hello \\*listener\\*"), "Failed \(ext): \(imported)")
}
let pdfURL = directory.appendingPathComponent("sample.pdf")
let data = NSMutableData()
let consumer = CGDataConsumer(data: data)!
var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
context.beginPDFPage(nil)
let line = CTLineCreateWithAttributedString(NSAttributedString(string: prose, attributes: [.font: NSFont.systemFont(ofSize: 16)]))
context.textPosition = CGPoint(x: 40, y: 700)
CTLineDraw(line, context)
context.endPDFPage()
context.closePDF()
try data.write(to: pdfURL)
precondition(try DocumentImport.text(from: pdfURL).contains("listener"))
let markdownURL = directory.appendingPathComponent("sample.md")
try "# Heading".write(to: markdownURL, atomically: true, encoding: .utf8)
precondition(try DocumentImport.text(from: markdownURL) == "# Heading")
let emptyURL = directory.appendingPathComponent("empty.txt")
try " ".write(to: emptyURL, atomically: true, encoding: .utf8)
do { _ = try DocumentImport.text(from: emptyURL); fatalError("Expected empty text rejection") } catch {}
print("PASS: PDF, DOCX, DOC, RTF, Markdown, and empty document handling")
'''
# Swift preconditions cannot contain throwing expressions.
harness = harness.replace('precondition(try DocumentImport.text(from: pdfURL).contains("listener"))', 'let pdfText = try DocumentImport.text(from: pdfURL)\nprecondition(pdfText.contains("listener"))').replace('precondition(try DocumentImport.text(from: markdownURL) == "# Heading")', 'let markdownText = try DocumentImport.text(from: markdownURL)\nprecondition(markdownText == "# Heading")')
with tempfile.TemporaryDirectory(prefix='audibleink-import-check-') as temp:
    swift = Path(temp) / 'main.swift'
    binary = Path(temp) / 'check'
    swift.write_text('import AppKit\nimport PDFKit\nimport CoreText\n' + extractor + harness)
    subprocess.run(['swiftc', '-module-cache-path', str(root / '.cache/clang'), str(swift), '-o', str(binary), '-framework', 'AppKit', '-framework', 'PDFKit'], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
