import XCTest
@testable import SafeShareLocalApp

final class SmokeTests: XCTestCase {
    func testProfilesEnum() {
        XCTAssertTrue(ProfileCode.allCases.contains(.medical))
    }

    func testCSVRedactionMasksNamesAndTimes() throws {
        let csv = """
        Patient Name,Appointment Time,Note
        Tao He,2026-04-25 10:30,Follow up
        Tao He,2026-04-25 10:30,Repeat
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let service = CSVRedactionService()
        let parsed = try service.readCSV(at: url)
        let columns = service.inferColumns(rows: parsed.rows)
        let result = service.redactRows(parsed.rows, columns: columns, strategy: .stableHash, dateShiftDays: 17)

        XCTAssertFalse(result.redactedText.contains("Tao He"))
        XCTAssertFalse(result.redactedText.contains("2026-04-25 10:30"))
        XCTAssertFalse(result.redactedText.contains("Follow up"))
        XCTAssertTrue(result.redactedText.contains("NAME_"))
        XCTAssertTrue(result.redactedText.contains("2026-05-12 10:30"))
        XCTAssertEqual(result.maskedColumnCount, 3)
        XCTAssertEqual(result.maskedCellCount, 6)
    }

    func testProviderLabelDetectionIncludesAuthorizingProvider() {
        let rule = ProfileCategoryRule(
            id: "provider-rule",
            profileCode: .medical,
            categoryCode: "provider_name",
            enabled: true,
            replacementToken: "[PROVIDER]",
            priority: 1
        )
        let content = """
        PCP: Sarah Chen, PA-C
        Authorizing provider: Sarah Chen
        """

        let entities = RuleEngine().detect(content: content, enabledRules: [rule], customPatterns: [])
        XCTAssertTrue(entities.contains { $0.categoryCode == "provider_name" && $0.rawValue == "Sarah Chen" })
    }
}
