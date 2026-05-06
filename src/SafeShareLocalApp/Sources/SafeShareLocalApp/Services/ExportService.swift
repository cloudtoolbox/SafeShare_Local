import Foundation

final class ExportService {
    private let pdfEngine = PDFRedactionEngine()

    func generateExports(
        jobId: String,
        document: IngestedDocument,
        entities: [RedactionEntity],
        includeFaceDetection: Bool,
        destinationDir: URL
    ) throws -> ExportArtifacts {
        let decisions = entities.filter { $0.decision != .keep }
        let redactedText = applyRedactions(to: document.text, entities: decisions)
        let summary = buildSummarySafeText(from: redactedText)
        let warnings = secondScanWarnings(content: redactedText)

        let stamp = Int(Date().timeIntervalSince1970)
        let base = document.originalName.replacingOccurrences(of: " ", with: "_")
        let redactedURL = destinationDir.appendingPathComponent("\(base)_redacted_\(stamp).txt")
        let summaryURL = destinationDir.appendingPathComponent("\(base)_summary_safe_\(stamp).txt")
        var redactedPDFPath: String?

        try redactedText.write(to: redactedURL, atomically: true, encoding: .utf8)
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)

        if document.sourceKind == .pdf {
            let pdfURL = destinationDir.appendingPathComponent("\(base)_redacted_\(stamp).pdf")
            try pdfEngine.burnInRedactions(
                sourcePDFURL: URL(fileURLWithPath: document.localPath),
                pageMaps: document.pageTextMaps,
                entities: decisions,
                includeFaceDetection: includeFaceDetection,
                outputURL: pdfURL
            )
            redactedPDFPath = pdfURL.path
        }

        return ExportArtifacts(
            redactedTextPath: redactedURL.path,
            redactedPDFPath: redactedPDFPath,
            summarySafePath: summaryURL.path,
            clipboardSafeText: redactedText,
            secondScanWarnings: warnings
        )
    }

    func generatePDFPreview(
        document: IngestedDocument,
        entities: [RedactionEntity],
        includeFaceDetection: Bool,
        destinationDir: URL
    ) throws -> String? {
        guard document.sourceKind == .pdf else { return nil }
        let decisions = entities.filter { $0.decision != .keep }
        let base = document.originalName.replacingOccurrences(of: " ", with: "_")
        let previewId = UUID().uuidString.lowercased()
        let path = destinationDir.appendingPathComponent("\(base)_preview_redacted_\(previewId).pdf")
        try pdfEngine.burnInRedactions(
            sourcePDFURL: URL(fileURLWithPath: document.localPath),
            pageMaps: document.pageTextMaps,
            entities: decisions,
            includeFaceDetection: includeFaceDetection,
            outputURL: path
        )
        return path.path
    }

    private func applyRedactions(to text: String, entities: [RedactionEntity]) -> String {
        let sorted = entities.sorted { $0.startOffset > $1.startOffset }
        var output = text
        for entity in sorted {
            guard entity.startOffset >= 0,
                  entity.endOffset <= output.count,
                  entity.endOffset > entity.startOffset,
                  let start = output.index(output.startIndex, offsetBy: entity.startOffset, limitedBy: output.endIndex),
                  let end = output.index(output.startIndex, offsetBy: entity.endOffset, limitedBy: output.endIndex)
            else { continue }
            output.replaceSubrange(start..<end, with: entity.effectiveToken)
        }
        return output
    }

    private func buildSummarySafeText(from redactedText: String) -> String {
        let lines = redactedText
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let header = "SafeShare Local Summary-Safe Output\n"
        let body = lines.prefix(12).joined(separator: "\n")
        return header + body
    }

    private func secondScanWarnings(content: String) -> [String] {
        let patterns = [
            #"\b(?:\+1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"#,
            #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            #"\b(?:MRN|Case\s*(?:No\.?|#|Number)?|Insurance\s*ID)[:\s#-]*[A-Z0-9-]{4,}\b"#
        ]

        var warnings: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
            if regex.firstMatch(in: content, options: [], range: nsRange) != nil {
                warnings.append("Second scan found potential leakage for pattern: \(pattern)")
            }
        }
        return warnings
    }
}
