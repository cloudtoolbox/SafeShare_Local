import CryptoKit
import Foundation

enum CSVRedactionError: Error {
    case unreadableContent
    case emptyCSV
}

final class CSVRedactionService {
    func readCSV(at url: URL) throws -> (text: String, rows: [[String]]) {
        let rawData = try Data(contentsOf: url)
        let text = String(data: rawData, encoding: .utf8)
            ?? String(data: rawData, encoding: .isoLatin1)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CSVRedactionError.unreadableContent
        }

        let rows = parseCSV(text)
        guard let headers = rows.first, !headers.isEmpty else {
            throw CSVRedactionError.emptyCSV
        }
        return (text, rows)
    }

    func readCSVText(_ text: String) throws -> [[String]] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CSVRedactionError.unreadableContent
        }
        let rows = parseCSV(text)
        guard let headers = rows.first, !headers.isEmpty else {
            throw CSVRedactionError.emptyCSV
        }
        return rows
    }

    func inferColumns(rows: [[String]]) -> [CSVColumnReview] {
        guard let headers = rows.first else { return [] }
        return headers.enumerated().map { index, header in
            let type = piiType(for: header)
            return CSVColumnReview(
                index: index,
                header: header,
                piiType: type,
                confidence: type == .nonPII ? 0.40 : 0.86,
                source: "rules"
            )
        }
    }

    func mergeColumnReviews(_ base: [CSVColumnReview], gemma: [CSVColumnReview]) -> [CSVColumnReview] {
        let gemmaByIndex = Dictionary(uniqueKeysWithValues: gemma.map { ($0.index, $0) })
        return base.map { local in
            guard let model = gemmaByIndex[local.index], model.piiType != .nonPII else { return local }
            if local.piiType == .nonPII || model.confidence >= local.confidence {
                return CSVColumnReview(
                    index: local.index,
                    header: local.header,
                    piiType: model.piiType,
                    confidence: model.confidence,
                    source: "gemma4"
                )
            }
            return local
        }
    }

    func redactRows(
        _ rows: [[String]],
        columns: [CSVColumnReview],
        strategy: CSVMaskStrategy,
        dateShiftDays: Int
    ) -> CSVRedactionResult {
        guard !rows.isEmpty else {
            return CSVRedactionResult(originalText: "", redactedText: "", maskedColumnCount: 0, maskedCellCount: 0, maskedHeaders: [])
        }

        var redactedRows = rows
        let targetColumns = columns.filter { $0.piiType != .nonPII }
        var maskedCellCount = 0

        for rowIndex in redactedRows.indices.dropFirst() {
            for column in targetColumns where column.index < redactedRows[rowIndex].count {
                let value = redactedRows[rowIndex][column.index].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                redactedRows[rowIndex][column.index] = replacement(
                    for: value,
                    type: column.piiType,
                    strategy: strategy,
                    dateShiftDays: dateShiftDays
                )
                maskedCellCount += 1
            }
        }

        return CSVRedactionResult(
            originalText: serializeCSV(rows),
            redactedText: serializeCSV(redactedRows),
            maskedColumnCount: targetColumns.count,
            maskedCellCount: maskedCellCount,
            maskedHeaders: targetColumns.map(\.header)
        )
    }

    func sampleRowsForGemma(_ rows: [[String]], limit: Int = 5) -> [[String]] {
        Array(rows.prefix(max(1, limit + 1)))
    }

    private func piiType(for header: String) -> CSVColumnPIIType {
        let normalized = header
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        if normalized.contains("note")
            || normalized.contains("comment")
            || normalized.contains("message")
            || normalized.contains("description")
            || normalized.contains("details")
            || normalized.contains("reason") {
            return .freeText
        }
        if normalized.contains("email") || normalized.contains("e mail") {
            return .email
        }
        if normalized.contains("phone") || normalized.contains("mobile") || normalized.contains("cell") || normalized.contains("fax") {
            return .phone
        }
        if normalized.contains("address") || normalized.contains("street") || normalized.contains("zip") || normalized.contains("postal") {
            return .address
        }
        if normalized.contains("date")
            || normalized.contains("time")
            || normalized == "dob"
            || normalized.contains("birth")
            || normalized.contains("timestamp")
            || normalized.contains("collected") {
            return .dateTime
        }
        if normalized.contains("name") {
            return .name
        }
        if normalized.contains("mrn")
            || normalized.contains("patient id")
            || normalized.contains("member id")
            || normalized.contains("insurance id")
            || normalized.contains("case")
            || normalized.hasSuffix(" id")
            || normalized == "id" {
            return .identifier
        }
        return .nonPII
    }

    private func replacement(
        for value: String,
        type: CSVColumnPIIType,
        strategy: CSVMaskStrategy,
        dateShiftDays: Int
    ) -> String {
        if type == .dateTime, let shifted = shiftDateTime(value, days: dateShiftDays) {
            return shifted
        }

        switch strategy {
        case .stableHash:
            let salt = "SafeShareLocal.CSV.v1"
            let digest = SHA256.hash(data: Data("\(salt)|\(type.tokenPrefix)|\(value)".utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "\(type.tokenPrefix)_\(hex.prefix(12))"
        case .guid:
            return "\(type.tokenPrefix)_\(UUID().uuidString)"
        }
    }

    private func shiftDateTime(_ value: String, days: Int) -> String? {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "MM/dd/yyyy HH:mm:ss",
            "MM/dd/yyyy HH:mm",
            "MM/dd/yyyy",
            "M/d/yyyy h:mm a",
            "M/d/yyyy",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            guard let date = formatter.date(from: value),
                  let shifted = Calendar.current.date(byAdding: .day, value: days, to: date) else {
                continue
            }
            return formatter.string(from: shifted)
        }

        return nil
    }

    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if character == "\"" {
                let next = text.index(after: index)
                if inQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = text.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !inQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""

                let next = text.index(after: index)
                if character == "\r", next < text.endIndex, text[next] == "\n" {
                    index = text.index(after: next)
                    continue
                }
            } else {
                field.append(character)
            }

            index = text.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        return rows.filter { !$0.allSatisfy { $0.isEmpty } }
    }

    private func serializeCSV(_ rows: [[String]]) -> String {
        rows
            .map { row in row.map(escapeCSVField).joined(separator: ",") }
            .joined(separator: "\n")
    }

    private func escapeCSVField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
