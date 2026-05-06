import Foundation
import SQLite3
import CryptoKit

final class SQLiteStore {
    private let db: OpaquePointer
    let dbPath: String

    init(dbPath: String) throws {
        self.dbPath = dbPath
        var dbPtr: OpaquePointer?
        if sqlite3_open(dbPath, &dbPtr) != SQLITE_OK {
            throw NSError(domain: "SQLiteStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to open DB: \(dbPath)"])
        }
        guard let dbPtr else {
            throw NSError(domain: "SQLiteStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "DB pointer missing"])
        }
        db = dbPtr
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
    }

    deinit {
        sqlite3_close(db)
    }

    func validateRequiredSchema() throws {
        let required = [
            "profiles",
            "profile_categories",
            "documents",
            "redaction_jobs",
            "entities"
        ]
        for table in required where !tableExists(table) {
            throw NSError(
                domain: "SQLiteStore",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Missing required table '\(table)' in DB: \(dbPath)"]
            )
        }
    }

    func ensureMedicalProviderCategory() throws {
        let now = Self.iso8601Now()
        let providerCategoryId = try ensureCategory(
            code: "provider_name",
            displayName: "Provider Name",
            description: "Clinician/provider personal name",
            now: now
        )
        let medicalProfileId = try profileId(for: .medical)
        try ensureProfileCategory(
            profileId: medicalProfileId,
            categoryId: providerCategoryId,
            enabled: true,
            replacementToken: "[PROVIDER_NAME]",
            priority: 110,
            now: now
        )

        if let facilityCategoryId = try? categoryId(forCode: "provider_facility_name") {
            try ensureProfileCategory(
                profileId: medicalProfileId,
                categoryId: facilityCategoryId,
                enabled: true,
                replacementToken: "[PROVIDER_FACILITY_NAME]",
                priority: 120,
                now: now
            )
        }
    }

    func loadProfiles() throws -> [AppProfile] {
        let sql = "SELECT id, code, display_name, description FROM profiles ORDER BY display_name"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare profiles") }
        defer { sqlite3_finalize(stmt) }

        var rows: [AppProfile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idC = sqlite3_column_text(stmt, 0),
                let codeC = sqlite3_column_text(stmt, 1),
                let nameC = sqlite3_column_text(stmt, 2),
                let code = ProfileCode(rawValue: String(cString: codeC))
            else { continue }
            let desc = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            rows.append(AppProfile(id: String(cString: idC), code: code, displayName: String(cString: nameC), description: desc))
        }
        return rows
    }

    func loadProfileRules(profile: ProfileCode) throws -> [ProfileCategoryRule] {
        let sql = """
        SELECT pc.id, p.code, c.code, pc.enabled, pc.replacement_token, pc.priority
        FROM profile_categories pc
        JOIN profiles p ON p.id = pc.profile_id
        JOIN categories c ON c.id = pc.category_id
        WHERE p.code = ?
        ORDER BY pc.priority ASC, c.code ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare profile rules") }
        defer { sqlite3_finalize(stmt) }
        bindText(profile.rawValue, to: stmt, at: 1)

        var rules: [ProfileCategoryRule] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idC = sqlite3_column_text(stmt, 0),
                let codeC = sqlite3_column_text(stmt, 1),
                let categoryC = sqlite3_column_text(stmt, 2),
                let replC = sqlite3_column_text(stmt, 4),
                let profileCode = ProfileCode(rawValue: String(cString: codeC))
            else { continue }

            rules.append(
                ProfileCategoryRule(
                    id: String(cString: idC),
                    profileCode: profileCode,
                    categoryCode: String(cString: categoryC),
                    enabled: sqlite3_column_int(stmt, 3) == 1,
                    replacementToken: String(cString: replC),
                    priority: Int(sqlite3_column_int(stmt, 5))
                )
            )
        }
        return rules
    }

    func updateProfileRule(id: String, enabled: Bool, replacementToken: String) throws {
        let sql = "UPDATE profile_categories SET enabled = ?, replacement_token = ?, updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare update profile rule") }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
        bindText(replacementToken, to: stmt, at: 2)
        bindText(Self.iso8601Now(), to: stmt, at: 3)
        bindText(id, to: stmt, at: 4)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("update profile rule") }
    }

    func loadCustomPatterns(profile: ProfileCode) throws -> [CustomPattern] {
        let sql = """
        SELECT cp.id, cp.profile_id, cp.pattern_type, cp.pattern_text, cp.replacement_token,
               cp.is_case_sensitive, cp.enabled, cp.notes
        FROM custom_patterns cp
        JOIN profiles p ON p.id = cp.profile_id
        WHERE p.code = ?
        ORDER BY cp.created_at DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare custom patterns") }
        defer { sqlite3_finalize(stmt) }
        bindText(profile.rawValue, to: stmt, at: 1)

        var patterns: [CustomPattern] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard
                let idC = sqlite3_column_text(stmt, 0),
                let profileIdC = sqlite3_column_text(stmt, 1),
                let typeC = sqlite3_column_text(stmt, 2),
                let patternC = sqlite3_column_text(stmt, 3),
                let replC = sqlite3_column_text(stmt, 4)
            else { continue }

            patterns.append(
                CustomPattern(
                    id: String(cString: idC),
                    profileId: String(cString: profileIdC),
                    patternType: String(cString: typeC),
                    patternText: String(cString: patternC),
                    replacementToken: String(cString: replC),
                    isCaseSensitive: sqlite3_column_int(stmt, 5) == 1,
                    enabled: sqlite3_column_int(stmt, 6) == 1,
                    notes: sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                )
            )
        }
        return patterns
    }

    func insertCustomPattern(profile: ProfileCode, type: String, patternText: String, replacementToken: String, caseSensitive: Bool) throws {
        let profileId = try profileId(for: profile)
        let sql = """
        INSERT INTO custom_patterns (id, profile_id, pattern_type, pattern_text, replacement_token, is_case_sensitive, enabled, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare insert custom pattern") }
        defer { sqlite3_finalize(stmt) }

        let now = Self.iso8601Now()
        bindText(UUID().uuidString.lowercased(), to: stmt, at: 1)
        bindText(profileId, to: stmt, at: 2)
        bindText(type, to: stmt, at: 3)
        bindText(patternText, to: stmt, at: 4)
        bindText(replacementToken, to: stmt, at: 5)
        sqlite3_bind_int(stmt, 6, caseSensitive ? 1 : 0)
        bindText(now, to: stmt, at: 7)
        bindText(now, to: stmt, at: 8)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("insert custom pattern") }
    }

    func insertDocument(name: String, sourceKind: SourceKind, localPath: String, text: String, pageCount: Int) throws -> IngestedDocument {
        let id = UUID().uuidString.lowercased()
        let now = Self.iso8601Now()
        let sha = Self.sha256(text)
        let sql = """
        INSERT INTO documents (id, original_name, source_kind, local_path, file_size_bytes, file_sha256, detected_language, ingestion_status, page_count, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 'en', 'ready', ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare insert document") }
        defer { sqlite3_finalize(stmt) }

        bindText(id, to: stmt, at: 1)
        bindText(name, to: stmt, at: 2)
        bindText(sourceKind.rawValue, to: stmt, at: 3)
        bindText(localPath, to: stmt, at: 4)
        sqlite3_bind_int64(stmt, 5, Int64(text.utf8.count))
        bindText(sha, to: stmt, at: 6)
        sqlite3_bind_int(stmt, 7, Int32(max(pageCount, 1)))
        bindText(now, to: stmt, at: 8)
        bindText(now, to: stmt, at: 9)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("insert document") }

        insertTextSpan(documentId: id, content: text)
        appendAuditLog(action: "document_ingested", entityType: "document", entityId: id, details: "{\"name\":\"\(name)\"}")

        return IngestedDocument(
            id: id,
            originalName: name,
            sourceKind: sourceKind,
            localPath: localPath,
            text: text,
            pageCount: pageCount,
            ocrLowConfidencePages: [],
            pageTextMaps: [],
            createdAt: Date()
        )
    }

    func insertRedactionJob(documentId: String, profile: ProfileCode, level: RedactionLevel) throws -> String {
        let id = UUID().uuidString.lowercased()
        let now = Self.iso8601Now()
        let profileId = try profileId(for: profile)
        let sql = """
        INSERT INTO redaction_jobs (id, document_id, profile_id, redaction_level, status, started_at, created_at, updated_at)
        VALUES (?, ?, ?, ?, 'running', ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare insert job") }
        defer { sqlite3_finalize(stmt) }

        bindText(id, to: stmt, at: 1)
        bindText(documentId, to: stmt, at: 2)
        bindText(profileId, to: stmt, at: 3)
        bindText(level.rawValue, to: stmt, at: 4)
        bindText(now, to: stmt, at: 5)
        bindText(now, to: stmt, at: 6)
        bindText(now, to: stmt, at: 7)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("insert redaction job") }
        return id
    }

    func replaceEntities(jobId: String, documentId: String, entities: [RedactionEntity]) throws {
        let deleteSQL = "DELETE FROM entities WHERE redaction_job_id = ?"
        var deleteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK else { throw error("prepare delete entities") }
        bindText(jobId, to: deleteStmt, at: 1)
        guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
            sqlite3_finalize(deleteStmt)
            throw error("delete entities")
        }
        sqlite3_finalize(deleteStmt)

        let insertSQL = """
        INSERT INTO entities (
            id, redaction_job_id, document_id, category_code, raw_value, replacement_token,
            confidence, detection_source, start_offset, end_offset, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare insert entities") }
        defer { sqlite3_finalize(stmt) }

        let now = Self.iso8601Now()
        for entity in entities {
            sqlite3_reset(stmt)
            bindText(entity.id, to: stmt, at: 1)
            bindText(jobId, to: stmt, at: 2)
            bindText(documentId, to: stmt, at: 3)
            bindText(entity.categoryCode, to: stmt, at: 4)
            bindText(entity.rawValue, to: stmt, at: 5)
            bindText(entity.replacementToken, to: stmt, at: 6)
            sqlite3_bind_double(stmt, 7, entity.confidence)
            bindText(entity.source.rawValue, to: stmt, at: 8)
            sqlite3_bind_int(stmt, 9, Int32(entity.startOffset))
            sqlite3_bind_int(stmt, 10, Int32(entity.endOffset))
            bindText(now, to: stmt, at: 11)
            bindText(now, to: stmt, at: 12)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("insert entity") }
        }

        markJobReview(jobId: jobId)
    }

    func upsertDecision(entity: RedactionEntity) throws {
        let deleteSQL = "DELETE FROM entity_decisions WHERE entity_id = ?"
        var deleteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK else { throw error("prepare delete decision") }
        bindText(entity.id, to: deleteStmt, at: 1)
        guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
            sqlite3_finalize(deleteStmt)
            throw error("delete decision")
        }
        sqlite3_finalize(deleteStmt)

        let sql = "INSERT INTO entity_decisions (id, entity_id, decision, edited_token, decided_by, created_at, updated_at) VALUES (?, ?, ?, ?, 'user', ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare insert decision") }
        defer { sqlite3_finalize(stmt) }

        let now = Self.iso8601Now()
        bindText(UUID().uuidString.lowercased(), to: stmt, at: 1)
        bindText(entity.id, to: stmt, at: 2)
        bindText(entity.decision.rawValue, to: stmt, at: 3)
        bindText(entity.editedToken, to: stmt, at: 4)
        bindText(now, to: stmt, at: 5)
        bindText(now, to: stmt, at: 6)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("upsert decision") }
    }

    func saveOutput(jobId: String, type: String, path: String?, content: String?, mime: String) throws {
        let sql = """
        INSERT INTO outputs (id, redaction_job_id, output_type, local_path, content_text, mime_type, byte_size, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare save output") }
        defer { sqlite3_finalize(stmt) }

        bindText(UUID().uuidString.lowercased(), to: stmt, at: 1)
        bindText(jobId, to: stmt, at: 2)
        bindText(type, to: stmt, at: 3)
        bindText(path, to: stmt, at: 4)
        bindText(content, to: stmt, at: 5)
        bindText(mime, to: stmt, at: 6)
        sqlite3_bind_int64(stmt, 7, Int64(content?.utf8.count ?? 0))
        bindText(Self.iso8601Now(), to: stmt, at: 8)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("save output") }
    }

    func appendAuditLog(action: String, entityType: String, entityId: String?, details: String) {
        let sql = "INSERT INTO audit_logs (id, actor, action, entity_type, entity_id, details_json, created_at) VALUES (?, 'user', ?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(UUID().uuidString.lowercased(), to: stmt, at: 1)
        bindText(action, to: stmt, at: 2)
        bindText(entityType, to: stmt, at: 3)
        bindText(entityId, to: stmt, at: 4)
        bindText(details, to: stmt, at: 5)
        bindText(Self.iso8601Now(), to: stmt, at: 6)
        sqlite3_step(stmt)
    }

    func clearHistory() throws {
        let sql = """
        DELETE FROM outputs;
        DELETE FROM entity_decisions;
        DELETE FROM entities;
        DELETE FROM redaction_jobs;
        DELETE FROM text_spans;
        DELETE FROM document_pages;
        DELETE FROM documents;
        DELETE FROM audit_logs;
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error("clear history") }
    }

    private func insertTextSpan(documentId: String, content: String) {
        let sql = """
        INSERT INTO text_spans (id, document_id, page_id, span_index, content, source_engine, created_at, updated_at)
        VALUES (?, ?, NULL, 0, ?, 'pdf_text', ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let now = Self.iso8601Now()
        bindText(UUID().uuidString.lowercased(), to: stmt, at: 1)
        bindText(documentId, to: stmt, at: 2)
        bindText(content, to: stmt, at: 3)
        bindText(now, to: stmt, at: 4)
        bindText(now, to: stmt, at: 5)
        sqlite3_step(stmt)
    }

    private func markJobReview(jobId: String) {
        let sql = "UPDATE redaction_jobs SET status = 'review', updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(Self.iso8601Now(), to: stmt, at: 1)
        bindText(jobId, to: stmt, at: 2)
        sqlite3_step(stmt)
    }

    private func profileId(for code: ProfileCode) throws -> String {
        let sql = "SELECT id FROM profiles WHERE code = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare profile lookup") }
        defer { sqlite3_finalize(stmt) }
        bindText(code.rawValue, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let idC = sqlite3_column_text(stmt, 0) else {
            throw NSError(domain: "SQLiteStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile missing: \(code.rawValue)"])
        }
        return String(cString: idC)
    }

    private func categoryId(forCode code: String) throws -> String {
        let sql = "SELECT id FROM categories WHERE code = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare category lookup") }
        defer { sqlite3_finalize(stmt) }
        bindText(code, to: stmt, at: 1)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let idC = sqlite3_column_text(stmt, 0) else {
            throw NSError(domain: "SQLiteStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Category missing: \(code)"])
        }
        return String(cString: idC)
    }

    private func ensureCategory(code: String, displayName: String, description: String, now: String) throws -> String {
        if let existing = try? categoryId(forCode: code) {
            return existing
        }

        let id = UUID().uuidString.lowercased()
        let sql = """
        INSERT INTO categories (id, code, display_name, description, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw error("prepare insert category") }
        defer { sqlite3_finalize(stmt) }

        bindText(id, to: stmt, at: 1)
        bindText(code, to: stmt, at: 2)
        bindText(displayName, to: stmt, at: 3)
        bindText(description, to: stmt, at: 4)
        bindText(now, to: stmt, at: 5)
        bindText(now, to: stmt, at: 6)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error("insert category") }
        return id
    }

    private func ensureProfileCategory(
        profileId: String,
        categoryId: String,
        enabled: Bool,
        replacementToken: String,
        priority: Int,
        now: String
    ) throws {
        let existsSql = "SELECT id FROM profile_categories WHERE profile_id = ? AND category_id = ? LIMIT 1"
        var existsStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, existsSql, -1, &existsStmt, nil) == SQLITE_OK else { throw error("prepare profile_category exists") }
        bindText(profileId, to: existsStmt, at: 1)
        bindText(categoryId, to: existsStmt, at: 2)
        let hasRow = sqlite3_step(existsStmt) == SQLITE_ROW
        sqlite3_finalize(existsStmt)

        if hasRow {
            let updateSql = """
            UPDATE profile_categories
            SET enabled = ?, replacement_token = ?, priority = ?, updated_at = ?
            WHERE profile_id = ? AND category_id = ?
            """
            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { throw error("prepare update profile_category") }
            defer { sqlite3_finalize(updateStmt) }
            sqlite3_bind_int(updateStmt, 1, enabled ? 1 : 0)
            bindText(replacementToken, to: updateStmt, at: 2)
            sqlite3_bind_int(updateStmt, 3, Int32(priority))
            bindText(now, to: updateStmt, at: 4)
            bindText(profileId, to: updateStmt, at: 5)
            bindText(categoryId, to: updateStmt, at: 6)
            guard sqlite3_step(updateStmt) == SQLITE_DONE else { throw error("update profile_category") }
            return
        }

        let insertSql = """
        INSERT INTO profile_categories (id, profile_id, category_id, enabled, replacement_token, priority, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else { throw error("prepare insert profile_category") }
        defer { sqlite3_finalize(insertStmt) }
        bindText(UUID().uuidString.lowercased(), to: insertStmt, at: 1)
        bindText(profileId, to: insertStmt, at: 2)
        bindText(categoryId, to: insertStmt, at: 3)
        sqlite3_bind_int(insertStmt, 4, enabled ? 1 : 0)
        bindText(replacementToken, to: insertStmt, at: 5)
        sqlite3_bind_int(insertStmt, 6, Int32(priority))
        bindText(now, to: insertStmt, at: 7)
        bindText(now, to: insertStmt, at: 8)
        guard sqlite3_step(insertStmt) == SQLITE_DONE else { throw error("insert profile_category") }
    }

    private func bindText(_ value: String?, to stmt: OpaquePointer?, at index: Int32) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func error(_ message: String) -> NSError {
        let cError = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
        return NSError(domain: "SQLiteStore", code: 500, userInfo: [NSLocalizedDescriptionKey: "\(message): \(cError)"])
    }

    private func tableExists(_ table: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(table, to: stmt, at: 1)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
