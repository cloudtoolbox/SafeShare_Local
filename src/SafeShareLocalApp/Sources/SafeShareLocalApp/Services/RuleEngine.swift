import Foundation

final class RuleEngine {
    func detect(content: String, enabledRules: [ProfileCategoryRule], customPatterns: [CustomPattern]) -> [RedactionEntity] {
        var entities: [RedactionEntity] = []
        let rulesByCategory = Dictionary(uniqueKeysWithValues: enabledRules.map { ($0.categoryCode, $0) })

        for (category, rule) in rulesByCategory where rule.enabled {
            entities.append(contentsOf: labelValueMatches(content: content, category: category, token: rule.replacementToken))

            let regexes = builtInRegexes(for: category)
            for regex in regexes {
                entities.append(contentsOf: matches(content: content, regex: regex, category: category, token: rule.replacementToken, source: .rule, confidence: 0.95))
            }
        }

        for pattern in customPatterns where pattern.enabled {
            let flags: NSRegularExpression.Options = pattern.isCaseSensitive ? [] : [.caseInsensitive]
            let escaped = pattern.patternType == "keyword" ? NSRegularExpression.escapedPattern(for: pattern.patternText) : pattern.patternText
            guard let regex = try? NSRegularExpression(pattern: escaped, options: flags) else { continue }
            entities.append(contentsOf: matches(content: content, regex: regex, category: "custom_pattern", token: pattern.replacementToken, source: .rule, confidence: 0.9))
        }

        if let providerToken = rulesByCategory["provider_name"]?.replacementToken {
            entities.append(contentsOf: expandProviderNameMentions(content: content, baseEntities: entities, token: providerToken))
        }

        entities = entities.filter(isPlausibleEntity)
        return mergeOverlaps(entities)
    }

    private func builtInRegexes(for category: String) -> [NSRegularExpression] {
        let patterns: [String]
        switch category {
        case "name", "student_name", "parent_name", "participant_name":
            patterns = [
                #"\b(?:Patient\s*Name|Legal\s*Name|Student\s*Name|Parent\s*Name|Participant\s*Name|Name)\s*[:\-]\s*[A-Z][A-Za-z'.,\-\s]{1,60}"#
            ]
        case "provider_name":
            patterns = [
                #"\b(?:PCP|Provider|Attending|Ordering\s*Provider|Rendering\s*Provider|Authorizing\s*Provider|Authorized\s*By)\s*[:\-]\s*[A-Z][A-Za-z'.,\-\s]{2,60}"#,
                #"(?m)^(?:[A-Z][A-Za-z'’.\-]+\s+){1,4}(?:MD|DO|PA-C|PA|NP|RN|MPAS|FNP-BC|DNP)\b.*$"#
            ]
        case "provider_facility_name":
            patterns = [
                #"(?m)^(?:University\s+of\s+[A-Z][A-Za-z&.\- ]{2,50}(?:Healthcare|Health|Hospital|Clinic|Clinics|Medical(?:\sCenter)?))$"#,
                #"(?m)^Department\s+of\s+[A-Z][A-Za-z&.\- ]{2,60}$"#,
                #"(?m)^[A-Z][A-Za-z&.\- ]{2,60}(?:Healthcare|Health|Hospital|Clinic|Clinics|Medical(?:\sCenter)?|Urgent\sCare)$"#
            ]
        case "phone":
            patterns = [#"\b(?:\+1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"#]
        case "email":
            patterns = [#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#]
        case "dob":
            patterns = [#"\b(?:DOB|Date of Birth)[:\s]*\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#, #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#]
        case "mrn":
            patterns = [#"\b(?:MRN|Medical Record Number)[:\s#-]*[A-Z0-9-]{4,}\b"#]
        case "insurance_id":
            patterns = [#"\b(?:Insurance\s*ID|Policy\s*#?)[:\s-]*[A-Z0-9-]{5,}\b"#]
        case "case_number":
            patterns = [#"\b(?:Case\s*(?:No\.?|#|Number)?)[:\s-]*[A-Z0-9-]{4,}\b"#]
        case "school_id":
            patterns = [#"\b(?:Student\s*ID|School\s*ID)[:\s-]*[A-Z0-9-]{4,}\b"#]
        case "address", "location_details":
            patterns = [#"\b\d{1,6}\s+[A-Za-z0-9.\s]+(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Lane|Ln|Dr|Drive|Ct|Court)\b(?:[\s,]+[A-Za-z\s]+){0,2}"#]
        default:
            patterns = []
        }

        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }

    private func labelValueMatches(content: String, category: String, token: String) -> [RedactionEntity] {
        let patterns: [String]
        switch category {
        case "name":
            patterns = [
                #"\b(?:Patient\s*Name|Legal\s*Name|Name)\s*[:\-]\s*([A-Za-z][A-Za-z'’.\-]+(?:\s+[A-Za-z][A-Za-z'’.\-]+){0,3})"#,
                #"\b(?:Pt\.?\s*Name)\s*[:\-]\s*([A-Za-z][A-Za-z'’.\-]+(?:\s+[A-Za-z][A-Za-z'’.\-]+){0,3})"#
            ]
        case "student_name":
            patterns = [#"\b(?:Student\s*Name|Name)\s*[:\-]\s*([A-Za-z][A-Za-z'’.\-]+(?:\s+[A-Za-z][A-Za-z'’.\-]+){0,3})"#]
        case "parent_name":
            patterns = [#"\b(?:Parent\s*Name|Guardian\s*Name)\s*[:\-]\s*([A-Za-z][A-Za-z'’.\-]+(?:\s+[A-Za-z][A-Za-z'’.\-]+){0,3})"#]
        case "participant_name":
            patterns = [#"\b(?:Participant\s*Name|Subject\s*Name)\s*[:\-]\s*([A-Za-z][A-Za-z'’.\-]+(?:\s+[A-Za-z][A-Za-z'’.\-]+){0,3})"#]
        case "provider_name":
            patterns = [
                #"\b(?:PCP|Provider|Attending|Ordering\s*Provider|Rendering\s*Provider|Authorizing\s*Provider|Authorized\s*By)\s*[:\-]\s*([A-Za-z][A-Za-z'’.\-]+(?:\s+[A-Za-z][A-Za-z'’.\-]+){0,4}(?:,\s*(?:MD|DO|PA-C|PA|NP|RN|MPAS|FNP-BC|DNP))?)"#,
                #"\b(?:Signed\s*by|Electronically\s*signed\s*by)\s*[:\-]\s*([A-Za-z][A-Za-z'’.\-]+(?:\s+[A-Za-z][A-Za-z'’.\-]+){0,4}(?:,\s*(?:MD|DO|PA-C|PA|NP|RN|MPAS|FNP-BC|DNP))?)"#
            ]
        case "provider_facility_name":
            patterns = [
                #"\b(?:Facility|Organization|Hospital|Clinic|Department)\s*[:\-]\s*([A-Za-z][A-Za-z&'’.\-\s]{3,80})"#
            ]
        default:
            patterns = []
        }

        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
            .flatMap { regex in
                captureMatches(content: content, regex: regex, captureGroup: 1, category: category, token: token, confidence: 0.98)
            }
    }

    private func matches(content: String, regex: NSRegularExpression, category: String, token: String, source: DetectionSource, confidence: Double) -> [RedactionEntity] {
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, options: [], range: nsRange).compactMap { result in
            guard let range = Range(result.range, in: content) else { return nil }
            let start = content.distance(from: content.startIndex, to: range.lowerBound)
            let end = content.distance(from: content.startIndex, to: range.upperBound)
            return RedactionEntity(
                id: UUID().uuidString.lowercased(),
                categoryCode: category,
                rawValue: String(content[range]),
                replacementToken: token,
                confidence: confidence,
                source: source,
                startOffset: start,
                endOffset: end,
                decision: .hide,
                editedToken: nil
            )
        }
    }

    private func isPlausibleEntity(_ entity: RedactionEntity) -> Bool {
        let value = entity.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count < 2 || value.count > 90 { return false }

        switch entity.categoryCode {
        case "name", "student_name", "parent_name", "participant_name":
            return isPlausiblePersonName(value)
        case "provider_name":
            return isPlausibleProviderName(value)
        case "provider_facility_name":
            return isPlausibleFacilityName(value)
        default:
            return true
        }
    }

    private func isPlausiblePersonName(_ value: String) -> Bool {
        if value.rangeOfCharacter(from: .decimalDigits) != nil { return false }
        let tokens = value
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
        if tokens.count < 2 || tokens.count > 5 { return false }
        return tokens.allSatisfy { token in
            guard let first = token.first else { return false }
            return first.isUppercase || token.contains(".")
        }
    }

    private func isPlausibleProviderName(_ value: String) -> Bool {
        let credentials = ["MD", "DO", "PA-C", "PA", "NP", "RN", "MPAS", "FNP-BC", "DNP"]
        let cleaned = value.uppercased()
        return isPlausiblePersonName(value) || credentials.contains(where: { cleaned.contains($0) })
    }

    private func isPlausibleFacilityName(_ value: String) -> Bool {
        if value.rangeOfCharacter(from: .decimalDigits) != nil { return false }
        let keywords = ["UNIVERSITY", "HEALTH", "HEALTHCARE", "HOSPITAL", "CLINIC", "CLINICS", "MEDICAL", "DEPARTMENT", "URGENT CARE", "PRACTICE", "CENTER"]
        let upper = value.uppercased()
        if !keywords.contains(where: { upper.contains($0) }) { return false }
        if upper.split(whereSeparator: \.isWhitespace).count < 2 { return false }
        return true
    }

    private func expandProviderNameMentions(content: String, baseEntities: [RedactionEntity], token: String) -> [RedactionEntity] {
        let providers = baseEntities.filter { $0.categoryCode == "provider_name" }
        guard !providers.isEmpty else { return [] }

        var expansions: [RedactionEntity] = []
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)

        for entity in providers {
            guard let name = canonicalProviderName(from: entity.rawValue) else { continue }
            let firstEscaped = NSRegularExpression.escapedPattern(for: name.first)
            let lastEscaped = NSRegularExpression.escapedPattern(for: name.last)
            let credentialPattern = #"(?:,\s*(?:MD|DO|PA-C|PA|NP|RN|MPAS|FNP-BC|DNP))*"#
            let pattern = "\\b\(firstEscaped)(?:\\s+[A-Z]\\.)?\\s+\(lastEscaped)\(credentialPattern)\\b"

            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: content, options: [], range: nsRange) {
                guard let range = Range(match.range, in: content) else { continue }
                let value = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isPlausibleProviderName(value) else { continue }

                let start = content.distance(from: content.startIndex, to: range.lowerBound)
                let end = content.distance(from: content.startIndex, to: range.upperBound)
                expansions.append(
                    RedactionEntity(
                        id: UUID().uuidString.lowercased(),
                        categoryCode: "provider_name",
                        rawValue: value,
                        replacementToken: token,
                        confidence: 0.97,
                        source: .rule,
                        startOffset: start,
                        endOffset: end,
                        decision: .hide,
                        editedToken: nil
                    )
                )
            }
        }

        return expansions
    }

    private func canonicalProviderName(from raw: String) -> (first: String, last: String)? {
        var cleaned = raw
        cleaned = cleaned.replacingOccurrences(of: #"\b(?:PCP|Provider|Attending|Ordering Provider|Rendering Provider|Authorizing Provider|Authorized By)\s*[:\-]\s*"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #",\s*(?:MD|DO|PA-C|PA|NP|RN|MPAS|FNP-BC|DNP)\b"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)

        let tokens = cleaned.split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return nil }

        let first = tokens.first!
        let last = tokens.last!
        guard first.first?.isUppercase == true, last.first?.isUppercase == true else { return nil }
        return (first, last)
    }

    private func captureMatches(
        content: String,
        regex: NSRegularExpression,
        captureGroup: Int,
        category: String,
        token: String,
        confidence: Double
    ) -> [RedactionEntity] {
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.matches(in: content, options: [], range: nsRange).compactMap { result in
            guard captureGroup < result.numberOfRanges,
                  let range = Range(result.range(at: captureGroup), in: content)
            else { return nil }

            let value = String(content[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2 else { return nil }

            let start = content.distance(from: content.startIndex, to: range.lowerBound)
            let end = content.distance(from: content.startIndex, to: range.upperBound)
            return RedactionEntity(
                id: UUID().uuidString.lowercased(),
                categoryCode: category,
                rawValue: value,
                replacementToken: token,
                confidence: confidence,
                source: .rule,
                startOffset: start,
                endOffset: end,
                decision: .hide,
                editedToken: nil
            )
        }
    }

    private func mergeOverlaps(_ entities: [RedactionEntity]) -> [RedactionEntity] {
        let sorted = entities.sorted {
            if $0.startOffset == $1.startOffset {
                return $0.confidence > $1.confidence
            }
            return $0.startOffset < $1.startOffset
        }

        var result: [RedactionEntity] = []
        for entity in sorted {
            if let last = result.last, entity.startOffset < last.endOffset {
                if entity.confidence > last.confidence {
                    _ = result.popLast()
                    result.append(entity)
                }
            } else {
                result.append(entity)
            }
        }
        return result
    }
}
