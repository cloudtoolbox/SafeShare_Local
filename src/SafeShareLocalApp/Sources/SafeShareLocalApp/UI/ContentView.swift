import SwiftUI

struct ContentView: View {
    @ObservedObject var vm: AppViewModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 290)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Import") { vm.showImporter = true }
                Button("Detect") { vm.runDetection() }
                    .disabled(vm.selectedMaterial == .csv || vm.currentDocument == nil || vm.isBusy)
                Button("Render PDF Preview") { vm.renderPDFPreviewIfNeeded() }
                    .disabled(vm.selectedMaterial == .csv || vm.currentDocument?.sourceKind != .pdf || vm.isBusy)
                Button("Export") { vm.exportAll() }
                    .disabled(!vm.canExport || vm.isBusy)
            }
        }
        .fileImporter(
            isPresented: $vm.showImporter,
            allowedContentTypes: vm.allowedImportTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let first = urls.first {
                vm.importFile(url: first)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("SafeShare Local")
                    .font(.system(size: 24, weight: .bold, design: .rounded))

                GroupBox("Mode") {
	                    VStack(alignment: .leading, spacing: 8) {
	                        Picker("Profile", selection: Binding(
	                            get: { vm.selectedProfile },
	                            set: { profile in
                                    DispatchQueue.main.async {
                                        vm.setProfile(profile)
                                    }
                                }
	                        )) {
                            ForEach(vm.profiles) { profile in
                                Text(profile.displayName).tag(profile.code)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Picker("Level", selection: $vm.selectedLevel) {
                            ForEach(RedactionLevel.allCases) { level in
                                Text(level.displayName).tag(level)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

	                        Picker("Material", selection: Binding(
	                            get: { vm.selectedMaterial },
	                            set: { material in
                                    DispatchQueue.main.async {
                                        vm.setMaterial(material)
                                    }
                                }
	                        )) {
                            ForEach(DocumentMaterial.allCases) { material in
                                Text(material.displayName).tag(material)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

	                        if vm.selectedMaterial == .csv {
	                            Picker("CSV Mask", selection: $vm.csvMaskStrategy) {
	                                ForEach(CSVMaskStrategy.allCases) { strategy in
	                                    Text(strategy.displayName).tag(strategy)
	                                }
	                            }
	                            .frame(maxWidth: .infinity, alignment: .leading)
	                            Stepper("Date Shift: \(vm.csvDateShiftDays) days", value: $vm.csvDateShiftDays, in: -365...365)
	                            Text("Stable Hash keeps repeated values linkable without exposing raw PII. GUID breaks linkage.")
	                                .font(.caption2)
	                                .foregroundStyle(.secondary)
	                        }
                    }
                }

                GroupBox("Category Toggles") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $vm.enableFaceDetection) {
                            HStack(spacing: 6) {
                                Text("vision_face_detection")
                                    .font(.system(.subheadline, design: .monospaced))
                                Text("Vision Face")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(vm.currentDocument?.sourceKind != .pdf && vm.currentDocument != nil)

                        Divider()

	                        ForEach(vm.profileRules) { rule in
	                            Toggle(isOn: Binding(
	                                get: { rule.enabled },
	                                set: { enabled in
                                        DispatchQueue.main.async {
                                            vm.updateRule(rule, enabled: enabled)
                                        }
                                    }
	                            )) {
                                Text(rule.categoryCode)
                                    .font(.system(.subheadline, design: .monospaced))
                            }
                        }
                    }
                }

                GroupBox("Custom Pattern") {
                    Picker("Type", selection: $vm.customPatternType) {
                        Text("keyword").tag("keyword")
                        Text("regex").tag("regex")
                    }
                    TextField("Pattern", text: $vm.customPatternInput)
                    TextField("Token", text: $vm.customPatternTokenInput)
                    Button("Add Pattern") { vm.addCustomPattern() }
                }

                GroupBox("Data") {
                    Button("Clear History", role: .destructive) { vm.clearHistory() }
                    if !vm.lastExportPaths.isEmpty {
                        ForEach(vm.lastExportPaths, id: \.self) { path in
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                reviewPanel
                entityPanel
            }
            .padding(12)

            Divider()
            statusBar
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.94, green: 0.97, blue: 1.0), Color(red: 0.97, green: 0.95, blue: 0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .dropDestination(for: URL.self) { items, _ in
            guard let first = items.first else { return false }
            vm.importFile(url: first)
            return true
        }
    }

    private var reviewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Document Preview")
                .font(.headline)
            if let doc = vm.currentDocument {
                Text("\(doc.originalName) · \(vm.selectedMaterial.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if vm.selectedMaterial == .csv {
                csvPreview
            } else if vm.currentDocument?.sourceKind == .pdf, let sourceURL = vm.sourcePDFURL {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Before")
                            .font(.subheadline.weight(.semibold))
                        PDFPreviewView(url: sourceURL)
                            .background(.white.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("After (Burn-in)")
                            .font(.subheadline.weight(.semibold))
                        if vm.jobId != nil || !vm.entities.isEmpty {
                            PDFPreviewView(
                                url: sourceURL,
                                pageMaps: vm.currentDocument?.pageTextMaps ?? [],
                                entities: vm.entities,
                                showsRedactionOverlay: true,
                                includesFaceDetection: vm.enableFaceDetection
                            )
                            .background(.white.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            if vm.pdfPreviewNeedsRender {
                                Text("Preview updates instantly. Export burns the current choices into the PDF.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(0.7))
                                .overlay(
                                    Text("Run Detect to preview redactions")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                )
                        }
                    }
                }
            } else {
                ScrollView {
                    Text(vm.highlightedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                        .background(.white.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var entityPanel: some View {
	        VStack(alignment: .leading, spacing: 8) {
	            if vm.selectedMaterial == .csv {
	                Text("Column Review (\(vm.csvColumnReviews.count))")
	                    .font(.headline)
	                ScrollView {
	                    LazyVStack(alignment: .leading, spacing: 8) {
	                        if vm.csvColumnReviews.isEmpty {
	                            VStack(alignment: .leading, spacing: 10) {
	                                Label("No black bars are used for CSV.", systemImage: "tablecells")
	                                Text("Import a CSV to let Gemma 4 and rules label columns.")
	                                    .font(.callout)
	                                    .foregroundStyle(.secondary)
	                            }
	                            .padding(12)
	                            .background(.white.opacity(0.85))
	                            .clipShape(RoundedRectangle(cornerRadius: 12))
	                        } else {
	                            ForEach(vm.csvColumnReviews) { column in
	                                CSVColumnCard(column: column) {
	                                    vm.updateCSVColumnType(columnIndex: column.index, type: $0)
	                                }
                                    .equatable()
	                            }
	                        }
	                    }
	                }
	                .frame(width: 420)
	                Text(vm.csvMaskSummary.isEmpty ? "CSV output updates after column labels change." : vm.csvMaskSummary)
	                    .font(.caption)
	                    .foregroundStyle(.secondary)
	            } else {
                Text("Review Queue (\(vm.entities.count))")
                    .font(.headline)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(vm.entities) { entity in
                            EntityCard(entity: entity,
                                       onDecisionChange: { vm.updateDecision(entityId: entity.id, decision: $0) },
                                       onTokenChange: { vm.updateEditedToken(entityId: entity.id, token: $0) })
                            .equatable()
                        }
                    }
                }
                .frame(width: 420)

                if !vm.exportWarnings.isEmpty {
                    Text("Second Scan Warnings")
                        .font(.subheadline.weight(.semibold))
                    ForEach(vm.exportWarnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(width: 430)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var statusBar: some View {
        HStack {
            Text(vm.status)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            if vm.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var csvPreview: some View {
        HStack(spacing: 12) {
            csvTextPane(title: "Before CSV", text: vm.csvOriginalText.isEmpty ? "Import a CSV file." : vm.csvOriginalText)
            csvTextPane(title: "After Masked CSV", text: vm.csvRedactedText.isEmpty ? "Masked output will appear here." : vm.csvRedactedText)
        }
    }

    private func csvTextPane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(.white.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct CSVColumnCard: View, Equatable {
    let column: CSVColumnReview
    let onTypeChange: (CSVColumnPIIType) -> Void

    nonisolated static func == (lhs: CSVColumnCard, rhs: CSVColumnCard) -> Bool {
        lhs.column == rhs.column
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(column.header.isEmpty ? "Column \(column.index + 1)" : column.header)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(column.source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker("Label", selection: Binding(
                get: { column.piiType },
                set: { type in
                    DispatchQueue.main.async {
                        onTypeChange(type)
                    }
                }
            )) {
                ForEach(CSVColumnPIIType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()

            Text(String(format: "Confidence %.2f", column.confidence))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct EntityCard: View, Equatable {
    let entity: RedactionEntity
    let onDecisionChange: (DecisionType) -> Void
    let onTokenChange: (String) -> Void

    @State private var tokenDraft = ""

    nonisolated static func == (lhs: EntityCard, rhs: EntityCard) -> Bool {
        lhs.entity == rhs.entity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entity.categoryCode)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())

                Spacer()
                Text(String(format: "%.2f", entity.confidence))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(entity.rawValue)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(2)

            Picker("Decision", selection: Binding(
                get: { entity.decision },
                set: { decision in
                    DispatchQueue.main.async {
                        onDecisionChange(decision)
                    }
                }
            )) {
                Text("Hide").tag(DecisionType.hide)
                Text("Keep").tag(DecisionType.keep)
                Text("Edit Token").tag(DecisionType.editToken)
            }
            .pickerStyle(.segmented)

            if entity.decision == .editToken {
                TextField(entity.replacementToken, text: Binding(
                    get: { tokenDraft.isEmpty ? (entity.editedToken ?? entity.replacementToken) : tokenDraft },
                    set: {
                        tokenDraft = $0
                        let token = $0
                        DispatchQueue.main.async {
                            onTokenChange(token)
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding(10)
        .background(.white.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }
}
