import Foundation
import PDFKit
import Vision
import UniformTypeIdentifiers

struct ParsedDocument {
    let sourceKind: SourceKind
    let originalName: String
    let localPath: String
    let text: String
    let pageCount: Int
    let ocrLowConfidencePages: [Int]
    let pageTextMaps: [DocumentPageTextMap]
}

enum DocumentParserError: Error {
    case unsupportedType
    case unreadableContent
}

final class DocumentParser {
    func parse(url: URL) async throws -> ParsedDocument {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return try parsePDF(url: url)
        }
        if ["png", "jpg", "jpeg", "tiff", "heic", "bmp"].contains(ext) {
            return try await parseImage(url: url)
        }
        if ["txt", "md", "rtf"].contains(ext) {
            return try parseText(url: url)
        }
        throw DocumentParserError.unsupportedType
    }

    private func parseText(url: URL) throws -> ParsedDocument {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            throw DocumentParserError.unreadableContent
        }
        return ParsedDocument(
            sourceKind: .text,
            originalName: url.lastPathComponent,
            localPath: url.path,
            text: text,
            pageCount: 1,
            ocrLowConfidencePages: [],
            pageTextMaps: []
        )
    }

    private func parsePDF(url: URL) throws -> ParsedDocument {
        guard let pdf = PDFDocument(url: url) else {
            throw DocumentParserError.unreadableContent
        }
        var pageMaps: [DocumentPageTextMap] = []
        var globalOffset = 0
        var allTextParts: [String] = []

        for idx in 0..<pdf.pageCount {
            let pageText = (pdf.page(at: idx)?.string ?? "")
            let start = globalOffset
            let end = start + pageText.count
            pageMaps.append(
                DocumentPageTextMap(
                    pageIndex: idx,
                    pageText: pageText,
                    globalStartOffset: start,
                    globalEndOffset: end
                )
            )
            allTextParts.append(pageText)
            globalOffset = end
            if idx < pdf.pageCount - 1 {
                globalOffset += 1
            }
        }

        let text = allTextParts.joined(separator: "\n")

        guard !text.isEmpty else {
            throw DocumentParserError.unreadableContent
        }

        return ParsedDocument(
            sourceKind: .pdf,
            originalName: url.lastPathComponent,
            localPath: url.path,
            text: text,
            pageCount: max(pdf.pageCount, 1),
            ocrLowConfidencePages: [],
            pageTextMaps: pageMaps
        )
    }

    private func parseImage(url: URL) async throws -> ParsedDocument {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(url: url)
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw DocumentParserError.unreadableContent
        }

        var textLines: [String] = []
        var lowConfidence = false
        for result in observations {
            guard let top = result.topCandidates(1).first else { continue }
            textLines.append(top.string)
            if top.confidence < 0.6 {
                lowConfidence = true
            }
        }

        let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw DocumentParserError.unreadableContent
        }

        return ParsedDocument(
            sourceKind: .image,
            originalName: url.lastPathComponent,
            localPath: url.path,
            text: text,
            pageCount: 1,
            ocrLowConfidencePages: lowConfidence ? [1] : [],
            pageTextMaps: []
        )
    }
}
