import Foundation

final class RedactionPipeline {
    private let ruleEngine = RuleEngine()
    private let gemmaClient = GemmaClient()

    func detect(
        content: String,
        profile: ProfileCode,
        level: RedactionLevel,
        rules: [ProfileCategoryRule],
        customPatterns: [CustomPattern]
    ) async -> [RedactionEntity] {
        let ruleEntities = ruleEngine.detect(content: content, enabledRules: rules, customPatterns: customPatterns)
        let modelEntities = await gemmaClient.detect(content: content, profile: profile, level: level, enabledRules: rules)
        return merge(ruleEntities: ruleEntities, modelEntities: modelEntities)
    }

    private func merge(ruleEntities: [RedactionEntity], modelEntities: [RedactionEntity]) -> [RedactionEntity] {
        let combined = (ruleEntities + modelEntities).sorted {
            if $0.startOffset == $1.startOffset {
                return $0.confidence > $1.confidence
            }
            return $0.startOffset < $1.startOffset
        }

        var output: [RedactionEntity] = []
        for entity in combined {
            if let last = output.last, overlaps(last, entity) {
                if entity.confidence > last.confidence {
                    _ = output.popLast()
                    output.append(entity)
                }
            } else {
                output.append(entity)
            }
        }
        return output
    }

    private func overlaps(_ lhs: RedactionEntity, _ rhs: RedactionEntity) -> Bool {
        lhs.startOffset < rhs.endOffset && rhs.startOffset < lhs.endOffset
    }
}
