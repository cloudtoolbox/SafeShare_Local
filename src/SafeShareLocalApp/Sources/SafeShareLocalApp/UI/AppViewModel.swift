import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    private static let faceDetectionKey = "safeshare.enable_face_detection"
    @Published var profiles: [AppProfile] = []
    @Published var selectedMaterial: DocumentMaterial = .pdf
    @Published var csvMaskStrategy: CSVMaskStrategy = .stableHash {
        didSet { recomputeCSVPreview() }
    }
    @Published var csvDateShiftDays: Int = 17 {
        didSet { recomputeCSVPreview() }
    }
    @Published var selectedProfile: ProfileCode = .medical
    @Published var selectedLevel: RedactionLevel = .medicalSafe
    @Published var profileRules: [ProfileCategoryRule] = []
    @Published var customPatterns: [CustomPattern] = []

    @Published var currentDocument: IngestedDocument?
    @Published var entities: [RedactionEntity] = []
    @Published var isBusy = false
    @Published var status = "Drop a file or choose one to start."
    @Published var jobId: String?

    @Published var showImporter = false
    @Published var importError: String?
    @Published var exportWarnings: [String] = []
    @Published var lastExportPaths: [String] = []
    @Published var sourcePDFURL: URL?
    @Published var redactedPreviewPDFURL: URL?
    @Published var pdfPreviewNeedsRender = false
    @Published var csvOriginalText = ""
    @Published var csvRedactedText = ""
    @Published var csvMaskSummary = ""
    @Published var csvColumnReviews: [CSVColumnReview] = []
    @Published var enableFaceDetection: Bool {
        didSet {
            UserDefaults.standard.set(enableFaceDetection, forKey: Self.faceDetectionKey)
            markPDFPreviewStaleIfNeeded()
        }
    }

    @Published var customPatternInput = ""
    @Published var customPatternTokenInput = "[CUSTOM]"
    @Published var customPatternType = "keyword"

    private let exporter = ExportService()
    private let csvRedactor = CSVRedactionService()
    private let gemmaClient = GemmaClient()
    private let db: SQLiteStore
    private var generatedPreviewURL: URL?

    init() {
        self.enableFaceDetection = UserDefaults.standard.object(forKey: Self.faceDetectionKey) as? Bool ?? true
        do {
            let dbPath = try Self.resolveDatabasePath()
            self.db = try SQLiteStore(dbPath: dbPath)
            try db.validateRequiredSchema()
            try db.ensureMedicalProviderCategory()
            self.status = "Ready. DB: \(dbPath)"
            try loadConfiguration()
        } catch {
            fatalError("Failed to initialize app: \(error.localizedDescription). Set SAFESHARE_DB_PATH if needed.")
        }
    }

    func loadConfiguration() throws {
        profiles = try db.loadProfiles()
        if !profiles.contains(where: { $0.code == selectedProfile }), let first = profiles.first {
            selectedProfile = first.code
        }
        profileRules = try db.loadProfileRules(profile: selectedProfile)
        customPatterns = try db.loadCustomPatterns(profile: selectedProfile)
    }

    func refreshRules() {
        do {
            profileRules = try db.loadProfileRules(profile: selectedProfile)
            customPatterns = try db.loadCustomPatterns(profile: selectedProfile)
        } catch {
            status = "Failed to load rules: \(error.localizedDescription)"
        }
    }

    func setProfile(_ profile: ProfileCode) {
        selectedProfile = profile
        refreshRules()
    }

    func setMaterial(_ material: DocumentMaterial) {
        selectedMaterial = material
        currentDocument = nil
        entities = []
        jobId = nil
        exportWarnings = []
        lastExportPaths = []
        sourcePDFURL = nil
        redactedPreviewPDFURL = nil
        generatedPreviewURL = nil
        pdfPreviewNeedsRender = false
        csvOriginalText = ""
        csvRedactedText = ""
        csvMaskSummary = ""
        csvColumnReviews = []
        status = material == .pdf
            ? "PDF mode selected. Import a PDF to redact with burn-in black bars."
            : "CSV mode selected. Import a CSV to replace PII cells with mask codes."
    }

    func importFile(url: URL) {
        Task {
            isBusy = true
            importError = nil
            defer { isBusy = false }

            do {
                if selectedMaterial == .csv {
                    try await importCSVFile(url: url)
                    return
                }

                let parser = DocumentParser()
                let parsed = try await parser.parse(url: url)
                let document = try db.insertDocument(
                    name: parsed.originalName,
                    sourceKind: parsed.sourceKind,
                    localPath: parsed.localPath,
                    text: parsed.text,
                    pageCount: parsed.pageCount
                )
                currentDocument = IngestedDocument(
                    id: document.id,
                    originalName: document.originalName,
                    sourceKind: document.sourceKind,
                    localPath: document.localPath,
                    text: parsed.text,
                    pageCount: parsed.pageCount,
                    ocrLowConfidencePages: parsed.ocrLowConfidencePages,
                    pageTextMaps: parsed.pageTextMaps,
                    createdAt: document.createdAt
                )
                entities = []
                jobId = nil
                exportWarnings = []
                lastExportPaths = []
                sourcePDFURL = parsed.sourceKind == .pdf ? URL(fileURLWithPath: parsed.localPath) : nil
                redactedPreviewPDFURL = nil
                generatedPreviewURL = nil
                pdfPreviewNeedsRender = false
                csvOriginalText = ""
                csvRedactedText = ""
                csvMaskSummary = ""
                csvColumnReviews = []
                status = "Imported \(parsed.originalName). Run detection next."
            } catch {
                importError = error.localizedDescription
                status = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    func runDetection() {
        if selectedMaterial == .csv {
            status = csvRedactedText.isEmpty
                ? "Import a CSV first. CSV masking runs during import."
                : "CSV already masked on import. Use Export to save the safe CSV."
            return
        }

        guard let document = currentDocument else {
            status = "Please import a document first."
            return
        }

        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let pipeline = RedactionPipeline()
                let newJobId = try db.insertRedactionJob(documentId: document.id, profile: selectedProfile, level: selectedLevel)
                let found = await pipeline.detect(
                    content: document.text,
                    profile: selectedProfile,
                    level: selectedLevel,
                    rules: profileRules,
                    customPatterns: customPatterns
                )
                try db.replaceEntities(jobId: newJobId, documentId: document.id, entities: found)
                for entity in found {
                    try db.upsertDecision(entity: entity)
                }
                jobId = newJobId
                entities = found
                status = "Detection complete: \(found.count) entities queued for review."
            } catch {
                status = "Detection failed: \(error.localizedDescription)"
            }
        }
    }

    func updateRule(_ rule: ProfileCategoryRule, enabled: Bool) {
        do {
            try db.updateProfileRule(id: rule.id, enabled: enabled, replacementToken: rule.replacementToken)
            refreshRules()
        } catch {
            status = "Rule update failed: \(error.localizedDescription)"
        }
    }

    func updateDecision(entityId: String, decision: DecisionType) {
        DispatchQueue.main.async { [weak self] in
            self?.applyDecisionUpdate(entityId: entityId, decision: decision)
        }
    }

    private func applyDecisionUpdate(entityId: String, decision: DecisionType) {
        guard let idx = entities.firstIndex(where: { $0.id == entityId }) else { return }
        entities[idx].decision = decision
        pdfPreviewNeedsRender = true
        status = "Review updated locally. Export burns the current choices into the PDF."
    }

    func updateEditedToken(entityId: String, token: String) {
        DispatchQueue.main.async { [weak self] in
            self?.applyEditedTokenUpdate(entityId: entityId, token: token)
        }
    }

    private func applyEditedTokenUpdate(entityId: String, token: String) {
        guard let idx = entities.firstIndex(where: { $0.id == entityId }) else { return }
        entities[idx].editedToken = token
        entities[idx].decision = .editToken
        pdfPreviewNeedsRender = true
        status = "Review updated locally. Export burns the current choices into the PDF."
    }

    func addCustomPattern() {
        let text = customPatternInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        do {
            try db.insertCustomPattern(
                profile: selectedProfile,
                type: customPatternType,
                patternText: text,
                replacementToken: customPatternTokenInput.isEmpty ? "[CUSTOM]" : customPatternTokenInput,
                caseSensitive: false
            )
            customPatternInput = ""
            customPatternTokenInput = "[CUSTOM]"
            refreshRules()
            status = "Custom pattern added."
        } catch {
            status = "Add pattern failed: \(error.localizedDescription)"
        }
    }

    func exportAll() {
        if selectedMaterial == .csv || !csvRedactedText.isEmpty {
            exportCSV()
            return
        }

        guard let document = currentDocument, let jobId else {
            status = "No detection job to export."
            return
        }

        do {
            guard let saveURL = chooseSaveURL(
                defaultName: defaultExportName(for: document.originalName, extension: "pdf"),
                allowedContentTypes: [.pdf]
            ) else {
                status = "Export cancelled."
                return
            }

            let outputDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("SafeShareExports", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try persistReviewDecisions()

            let artifacts = try exporter.generateExports(
                jobId: jobId,
                document: document,
                entities: entities,
                includeFaceDetection: enableFaceDetection,
                destinationDir: outputDir
            )

            guard let redactedPDFPath = artifacts.redactedPDFPath else {
                status = "Export failed: PDF output was not generated."
                return
            }

            if FileManager.default.fileExists(atPath: saveURL.path) {
                try FileManager.default.removeItem(at: saveURL)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: redactedPDFPath), to: saveURL)

            try db.saveOutput(jobId: jobId, type: "redacted_document", path: saveURL.path, content: nil, mime: "application/pdf")
            db.appendAuditLog(action: "export", entityType: "redaction_job", entityId: jobId, details: "{\"profile\":\"\(selectedProfile.rawValue)\"}")

            exportWarnings = artifacts.secondScanWarnings
            redactedPreviewPDFURL = saveURL
            generatedPreviewURL = nil
            pdfPreviewNeedsRender = false
            lastExportPaths = [saveURL.path]
            status = "Export complete: \(saveURL.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    func clearHistory() {
        do {
            try db.clearHistory()
            currentDocument = nil
            entities = []
            jobId = nil
            exportWarnings = []
            lastExportPaths = []
            sourcePDFURL = nil
            redactedPreviewPDFURL = nil
            generatedPreviewURL = nil
            pdfPreviewNeedsRender = false
            csvOriginalText = ""
            csvRedactedText = ""
            csvMaskSummary = ""
            csvColumnReviews = []
            status = "Local task history cleared."
        } catch {
            status = "Clear history failed: \(error.localizedDescription)"
        }
    }

    func renderPDFPreviewIfNeeded() {
        guard let document = currentDocument, document.sourceKind == .pdf else { return }
        do {
            try persistReviewDecisions()
            let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("SafeSharePreview", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            removeGeneratedPreview()
            if let path = try exporter.generatePDFPreview(
                document: document,
                entities: entities,
                includeFaceDetection: enableFaceDetection,
                destinationDir: dir
            ) {
                let url = URL(fileURLWithPath: path)
                generatedPreviewURL = url
                redactedPreviewPDFURL = url
                pdfPreviewNeedsRender = false
            }
        } catch {
            status = "PDF preview failed: \(error.localizedDescription)"
        }
    }

    var highlightedText: AttributedString {
        guard let text = currentDocument?.text else {
            return AttributedString("No document loaded")
        }

        var output = AttributedString(text)
        let targets = entities
            .filter { $0.decision != .keep }
            .sorted { $0.startOffset > $1.startOffset }

        for entity in targets {
            guard let range = rangeInAttributedString(text: text, start: entity.startOffset, end: entity.endOffset, in: output) else { continue }
            output[range].backgroundColor = .orange.opacity(0.35)
            output[range].foregroundColor = .primary
        }

        return output
    }

    var canExport: Bool {
        if selectedMaterial == .csv || !csvRedactedText.isEmpty {
            return !csvRedactedText.isEmpty
        }
        return currentDocument?.sourceKind == .pdf && jobId != nil
    }

    var allowedImportTypes: [UTType] {
        switch selectedMaterial {
        case .pdf:
            return [.pdf]
        case .csv:
            return [.commaSeparatedText, .text, .plainText]
        }
    }

    func updateCSVColumnType(columnIndex: Int, type: CSVColumnPIIType) {
        guard let idx = csvColumnReviews.firstIndex(where: { $0.index == columnIndex }) else { return }
        csvColumnReviews[idx].piiType = type
        csvColumnReviews[idx].confidence = 1.0
        csvColumnReviews[idx].source = "user"
        recomputeCSVPreview()
    }

    private func importCSVFile(url: URL) async throws {
        guard url.pathExtension.lowercased() == "csv" else {
            throw NSError(
                domain: "SafeShareLocalApp",
                code: 415,
                userInfo: [NSLocalizedDescriptionKey: "CSV mode only accepts .csv files."]
            )
        }

        let parsed = try csvRedactor.readCSV(at: url)
        let localReviews = csvRedactor.inferColumns(rows: parsed.rows)
        let headers = parsed.rows.first ?? []
        let gemmaReviews = await gemmaClient.classifyCSVColumns(
            headers: headers,
            sampleRows: csvRedactor.sampleRowsForGemma(parsed.rows),
            profile: selectedProfile
        )
        let mergedReviews = csvRedactor.mergeColumnReviews(localReviews, gemma: gemmaReviews)
        let result = csvRedactor.redactRows(
            parsed.rows,
            columns: mergedReviews,
            strategy: csvMaskStrategy,
            dateShiftDays: csvDateShiftDays
        )
        let document = try db.insertDocument(
            name: url.lastPathComponent,
            sourceKind: .text,
            localPath: url.path,
            text: parsed.text,
            pageCount: 1
        )

        currentDocument = IngestedDocument(
            id: document.id,
            originalName: document.originalName,
            sourceKind: document.sourceKind,
            localPath: document.localPath,
            text: parsed.text,
            pageCount: 1,
            ocrLowConfidencePages: [],
            pageTextMaps: [],
            createdAt: document.createdAt
        )
        entities = []
        jobId = nil
        exportWarnings = []
        lastExportPaths = []
        sourcePDFURL = nil
        redactedPreviewPDFURL = nil
        csvOriginalText = parsed.text
        csvRedactedText = result.redactedText
        csvColumnReviews = mergedReviews
        let maskedHeaders = result.maskedHeaders.isEmpty ? "none" : result.maskedHeaders.joined(separator: ", ")
        csvMaskSummary = "Masked \(result.maskedCellCount) cells across \(result.maskedColumnCount) columns: \(maskedHeaders). Date/time shift: \(csvDateShiftDays) days."
        status = "Imported CSV. \(csvMaskSummary)"
    }

    private func recomputeCSVPreview() {
        guard selectedMaterial == .csv,
              !csvOriginalText.isEmpty,
              let rows = try? csvRedactor.readCSVText(csvOriginalText) else {
            return
        }
        let result = csvRedactor.redactRows(
            rows,
            columns: csvColumnReviews,
            strategy: csvMaskStrategy,
            dateShiftDays: csvDateShiftDays
        )
        csvRedactedText = result.redactedText
        let headers = result.maskedHeaders.isEmpty ? "none" : result.maskedHeaders.joined(separator: ", ")
        csvMaskSummary = "Masked \(result.maskedCellCount) cells across \(result.maskedColumnCount) columns: \(headers). Date/time shift: \(csvDateShiftDays) days."
    }

    private func markPDFPreviewStaleIfNeeded() {
        guard currentDocument?.sourceKind == .pdf else { return }
        pdfPreviewNeedsRender = true
        removeGeneratedPreview()
    }

    private func removeGeneratedPreview() {
        redactedPreviewPDFURL = nil
        if let generatedPreviewURL,
           FileManager.default.fileExists(atPath: generatedPreviewURL.path) {
            try? FileManager.default.removeItem(at: generatedPreviewURL)
        }
        generatedPreviewURL = nil
    }

    private func persistReviewDecisions() throws {
        for entity in entities {
            try db.upsertDecision(entity: entity)
        }
    }

    private func exportCSV() {
        guard !csvRedactedText.isEmpty else {
            status = "No masked CSV to export."
            return
        }

        do {
            let defaultName = defaultExportName(for: currentDocument?.originalName ?? "SafeShare.csv", extension: "csv")
            guard let saveURL = chooseSaveURL(defaultName: defaultName, allowedContentTypes: [.commaSeparatedText]) else {
                status = "Export cancelled."
                return
            }

            try csvRedactedText.write(to: saveURL, atomically: true, encoding: .utf8)
            lastExportPaths = [saveURL.path]
            exportWarnings = []
            status = "CSV export complete: \(saveURL.lastPathComponent)"
        } catch {
            status = "CSV export failed: \(error.localizedDescription)"
        }
    }

    private func chooseSaveURL(defaultName: String, allowedContentTypes: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = allowedContentTypes
        panel.nameFieldStringValue = defaultName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func defaultExportName(for originalName: String, extension pathExtension: String) -> String {
        let base = URL(fileURLWithPath: originalName)
            .deletingPathExtension()
            .lastPathComponent
            .isEmpty ? "SafeShare" : URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
        return "\(base)_safeshare_redacted.\(pathExtension)"
    }

    private func rangeInAttributedString(text: String, start: Int, end: Int, in attributed: AttributedString) -> Range<AttributedString.Index>? {
        guard start >= 0, end > start, end <= text.count else { return nil }
        let nsRange = NSRange(location: start, length: end - start)
        guard let swiftRange = Range(nsRange, in: text) else { return nil }
        let attrStart = AttributedString.Index(swiftRange.lowerBound, within: attributed)
        let attrEnd = AttributedString.Index(swiftRange.upperBound, within: attributed)
        guard let attrStart, let attrEnd else { return nil }
        return attrStart..<attrEnd
    }

    private static func resolveDatabasePath() throws -> String {
        let fm = FileManager.default
        var candidates: [String] = []

        let env = ProcessInfo.processInfo.environment
        if let explicit = env["SAFESHARE_DB_PATH"], !explicit.isEmpty {
            candidates.append((explicit as NSString).expandingTildeInPath)
        }

        let cwd = fm.currentDirectoryPath
        candidates.append((cwd as NSString).appendingPathComponent("SafeShareApp.DB"))
        candidates.append((cwd as NSString).appendingPathComponent("../SafeShareApp.DB"))
        candidates.append((cwd as NSString).appendingPathComponent("../../SafeShareApp.DB"))

        let sourceURL = URL(fileURLWithPath: #filePath)
        let packageRoot = sourceURL
            .deletingLastPathComponent() // UI
            .deletingLastPathComponent() // SafeShareLocalApp
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // SafeShareLocalApp (package root)
        candidates.append(packageRoot.appendingPathComponent("SafeShareApp.DB").path)
        candidates.append(packageRoot.deletingLastPathComponent().appendingPathComponent("SafeShareApp.DB").path)

        var checked: [String] = []
        var seen = Set<String>()

        for candidate in candidates where !candidate.isEmpty {
            let normalized = (candidate as NSString).standardizingPath
            guard seen.insert(normalized).inserted else { continue }
            guard fm.fileExists(atPath: normalized) else { continue }

            checked.append(normalized)
            if let store = try? SQLiteStore(dbPath: normalized) {
                if (try? store.validateRequiredSchema()) != nil {
                    return normalized
                }
            }
        }

        throw NSError(
            domain: "SafeShareLocalApp",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "No valid SafeShareApp.DB with required schema found. Checked: \(checked.joined(separator: ", "))"]
        )
    }
}
