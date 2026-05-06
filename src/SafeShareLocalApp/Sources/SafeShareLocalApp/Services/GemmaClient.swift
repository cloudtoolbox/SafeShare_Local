import Foundation

final class GemmaClient: @unchecked Sendable {
    private let endpoint: URL
    private let modelName: String

    init(endpoint: URL? = nil, modelName: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        if let endpoint {
            self.endpoint = endpoint
        } else if let raw = env["OLLAMA_ENDPOINT"], let url = URL(string: raw), !raw.isEmpty {
            self.endpoint = url
        } else {
            self.endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!
        }

        if let modelName, !modelName.isEmpty {
            self.modelName = modelName
        } else if let envModel = env["OLLAMA_MODEL"], !envModel.isEmpty {
            self.modelName = envModel
        } else {
            self.modelName = "Gemma4:e4b"
        }
    }

    func detect(content: String, profile: ProfileCode, level: RedactionLevel, enabledRules: [ProfileCategoryRule]) async -> [RedactionEntity] {
        let prompt = loadPromptTemplate(profile: profile)
        let categoryFilter = Set(enabledRules.filter { $0.enabled }.map(\.categoryCode))

        let userPayload: [String: Any] = [
            "profile_code": profile.rawValue,
            "redaction_level": level.rawValue,
            "document_language": "en",
            "content": content
        ]

        let requestBody: [String: Any] = [
            "model": modelName,
            "stream": false,
            "format": "json",
            "options": [
                "temperature": 0.1
            ],
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": jsonString(userPayload)]
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else { return [] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 400 else { return [] }
            let raw = extractTextFromOllama(data: data)
            return parseModelEntities(raw: raw, content: content, categoryFilter: categoryFilter)
        } catch {
            return []
        }
    }

    func classifyCSVColumns(headers: [String], sampleRows: [[String]], profile: ProfileCode) async -> [CSVColumnReview] {
        let systemPrompt = """
        You classify CSV columns for local privacy redaction. Return strict JSON only.
        Allowed pii_type values: non_pii, name, date_time, phone, email, address, identifier, free_text.
        Use date_time for DOB, dates, times, timestamps, appointment times, collection times.
        Use free_text for notes/comments/messages/details that may contain embedded PII.
        Output shape: {"columns":[{"index":0,"name":"Patient Name","pii_type":"name","confidence":0.95,"reason":"..."}]}
        """

        let userPayload: [String: Any] = [
            "profile_code": profile.rawValue,
            "headers": headers,
            "sample_rows": sampleRows
        ]

        let requestBody: [String: Any] = [
            "model": modelName,
            "stream": false,
            "format": "json",
            "options": [
                "temperature": 0.0
            ],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": jsonString(userPayload)]
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: requestBody) else { return [] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode ?? 500 < 400 else { return [] }
            let raw = extractTextFromOllama(data: data)
            return parseCSVColumnPayload(raw: raw, headers: headers)
        } catch {
            return []
        }
    }

    private func parseModelEntities(raw: String, content: String, categoryFilter: Set<String>) -> [RedactionEntity] {
        guard let jsonData = sanitizeJson(raw).data(using: .utf8),
              let payload = try? JSONDecoder().decode(ModelPayload.self, from: jsonData) else {
            return []
        }

        return payload.entities.compactMap { entity in
            guard categoryFilter.isEmpty || categoryFilter.contains(entity.category) else { return nil }
            let value = entity.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }

            let offsets = resolveOffsets(value: value, content: content, providedStart: entity.startOffset, providedEnd: entity.endOffset)
            return RedactionEntity(
                id: UUID().uuidString.lowercased(),
                categoryCode: entity.category,
                rawValue: value,
                replacementToken: entity.replacementToken,
                confidence: entity.confidence,
                source: .model,
                startOffset: offsets.0,
                endOffset: offsets.1,
                decision: .hide,
                editedToken: nil
            )
        }
    }

    private func parseCSVColumnPayload(raw: String, headers: [String]) -> [CSVColumnReview] {
        guard let jsonData = sanitizeJson(raw).data(using: .utf8),
              let payload = try? JSONDecoder().decode(CSVColumnPayload.self, from: jsonData) else {
            return []
        }

        return payload.columns.compactMap { column in
            guard column.index >= 0, column.index < headers.count,
                  let type = CSVColumnPIIType(rawValue: column.piiType) else {
                return nil
            }
            return CSVColumnReview(
                index: column.index,
                header: headers[column.index],
                piiType: type,
                confidence: min(max(column.confidence, 0.0), 1.0),
                source: "gemma4"
            )
        }
    }

    private func resolveOffsets(value: String, content: String, providedStart: Int?, providedEnd: Int?) -> (Int, Int) {
        if let s = providedStart, let e = providedEnd, s >= 0, e > s, e <= content.count {
            return (s, e)
        }
        if let range = content.range(of: value) {
            let start = content.distance(from: content.startIndex, to: range.lowerBound)
            let end = content.distance(from: content.startIndex, to: range.upperBound)
            return (start, end)
        }
        return (0, min(value.count, max(1, content.count)))
    }

    private func loadPromptTemplate(profile: ProfileCode) -> String {
        let name: String
        switch profile {
        case .medical: name = "gemma4_medical_prompt"
        case .studentFamily: name = "gemma4_student_family_prompt"
        case .researchSocialServices: name = "gemma4_research_prompt"
        case .custom: name = "gemma4_medical_prompt"
        }

        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif

        guard let url = bundle.url(forResource: name, withExtension: "md", subdirectory: "Resources/Prompts"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "Detect sensitive entities and output strict JSON."
        }
        return text
    }

    private func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func extractTextFromOllama(data: Data) -> String {
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = envelope["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let response = envelope["response"] as? String {
            return response
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func sanitizeJson(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            return trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }
}

private struct ModelPayload: Decodable {
    let profile: String?
    let redactionLevel: String?
    let entities: [ModelEntity]
}

private struct ModelEntity: Decodable {
    let category: String
    let value: String
    let startOffset: Int?
    let endOffset: Int?
    let confidence: Double
    let replacementToken: String
    let reason: String?
}

private struct CSVColumnPayload: Decodable {
    let columns: [CSVColumnModel]
}

private struct CSVColumnModel: Decodable {
    let index: Int
    let name: String?
    let piiType: String
    let confidence: Double
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case name
        case piiType = "pii_type"
        case confidence
        case reason
    }
}
