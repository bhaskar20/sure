// sure-ocr: reads the text of a scanned or image-only PDF with Apple's Vision
// framework, entirely on this Mac.
//
// Usage: sure-ocr <file.pdf> [max-pages]
// Prints each page's text followed by a form feed (\f). Words keep their
// horizontal position on a fixed character grid, so table columns stay apart
// the way pdf-reader lays out a text PDF and the statement parser can read
// them.
import AppKit
import Foundation
import PDFKit
import Vision

let renderScale: CGFloat = 3        // ~216 dpi; small statement print stays legible
let columnsPerLine: CGFloat = 160   // character grid width for one page

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func render(_ page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let width = Int(bounds.width * renderScale), height = Int(bounds.height * renderScale)
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.setFillColor(.white)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: renderScale, y: renderScale)
    context.translateBy(x: -bounds.minX, y: -bounds.minY)
    page.draw(with: .mediaBox, to: context)
    return context.makeImage()
}

func recognize(_ image: CGImage) throws -> [(box: CGRect, text: String)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { observation in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        return (observation.boundingBox, text)
    }
}

// Groups observations into lines by vertical centre (Vision's origin is the
// bottom left), then places each on the character grid by its left edge.
func layout(_ items: [(box: CGRect, text: String)]) -> String {
    var lines: [(y: CGFloat, height: CGFloat, items: [(box: CGRect, text: String)])] = []
    for item in items.sorted(by: { $0.box.midY > $1.box.midY }) {
        if let i = lines.firstIndex(where: { abs($0.y - item.box.midY) < max($0.height, item.box.height) * 0.5 }) {
            lines[i].items.append(item)
        } else {
            lines.append((item.box.midY, item.box.height, [item]))
        }
    }
    return lines.sorted(by: { $0.y > $1.y }).map { line in
        var out = ""
        for item in line.items.sorted(by: { $0.box.minX < $1.box.minX }) {
            let column = Int(item.box.minX * columnsPerLine)
            // At least two spaces between separate observations: they are
            // separate cells, and the parser treats two spaces as a column gap.
            let gap = out.isEmpty ? column : max(column - out.count, 2)
            out += String(repeating: " ", count: gap) + item.text
        }
        return out
    }.joined(separator: "\n")
}

let args = CommandLine.arguments
guard args.count == 2 || args.count == 3 else { fail("usage: sure-ocr <file.pdf> [max-pages]") }
let maxPages = args.count == 3 ? Int(args[2]) : nil
if args.count == 3 && (maxPages ?? 0) < 1 { fail("max-pages must be a positive number") }
guard let document = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    fail("cannot open PDF")
}
if document.isLocked { fail("PDF is password protected") }

for index in 0..<min(document.pageCount, maxPages ?? Int.max) {
    autoreleasepool {
        guard let page = document.page(at: index), let image = render(page) else {
            print("\u{0C}", terminator: "")
            return
        }
        do {
            print(layout(try recognize(image)), terminator: "\n\u{0C}")
        } catch {
            fail("OCR failed on page \(index + 1): \(error.localizedDescription)")
        }
    }
}
