import Foundation
import SQLite3

enum VoiceprintDatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            "打开声纹数据库失败：\(message)"
        case .prepareFailed(let message):
            "准备声纹数据库语句失败：\(message)"
        case .stepFailed(let message):
            "写入声纹数据库失败：\(message)"
        }
    }
}

final class VoiceprintDatabase {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.sortedKeys]
    }

    func loadRecords() -> [VoiceprintRecord] {
        do {
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try migrate(database)

            let sql = """
            SELECT id, name, voiceprint, role, confidence, embedding_json, updated_at
            FROM voiceprints
            ORDER BY updated_at DESC
            """
            let statement = try prepare(sql, database: database)
            defer { sqlite3_finalize(statement) }

            var records: [VoiceprintRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = Self.columnText(statement, index: 0),
                      let id = UUID(uuidString: idText),
                      let embeddingText = Self.columnText(statement, index: 5),
                      let embeddingData = embeddingText.data(using: .utf8),
                      let embedding = try? decoder.decode([Double].self, from: embeddingData) else {
                    continue
                }
                records.append(
                    VoiceprintRecord(
                        id: id,
                        name: Self.columnText(statement, index: 1) ?? "未命名声纹",
                        voiceprint: Self.columnText(statement, index: 2) ?? "VP-CAM",
                        role: Self.columnText(statement, index: 3) ?? "待确认",
                        confidence: Self.columnText(statement, index: 4) ?? "--",
                        embedding: embedding,
                        updatedAt: Self.date(from: Self.columnText(statement, index: 6)) ?? Date()
                    )
                )
            }
            return records
        } catch {
            return []
        }
    }

    func upsert(_ record: VoiceprintRecord) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try migrate(database)
        try upsert(record, database: database)
    }

    func replaceAll(_ records: [VoiceprintRecord]) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try migrate(database)
        try exec("BEGIN IMMEDIATE TRANSACTION", database: database)
        do {
            try exec("DELETE FROM voiceprints", database: database)
            for record in records {
                try upsert(record, database: database)
            }
            try exec("COMMIT", database: database)
        } catch {
            try? exec("ROLLBACK", database: database)
            throw error
        }
    }

    func migrateFromJSONIfNeeded(records: [VoiceprintRecord]) {
        guard !records.isEmpty, loadRecords().isEmpty else { return }
        for record in records {
            try? upsert(record)
        }
    }

    private func upsert(_ record: VoiceprintRecord, database: OpaquePointer?) throws {
        let sql = """
        INSERT INTO voiceprints (id, name, voiceprint, role, confidence, embedding_json, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            voiceprint = excluded.voiceprint,
            role = excluded.role,
            confidence = excluded.confidence,
            embedding_json = excluded.embedding_json,
            updated_at = excluded.updated_at
        """
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }

        let embeddingData = try encoder.encode(record.embedding)
        let embeddingText = String(data: embeddingData, encoding: .utf8) ?? "[]"

        sqlite3_bind_text(statement, 1, record.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, record.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, record.voiceprint, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, record.role, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 5, record.confidence, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 6, embeddingText, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 7, Self.isoString(from: record.updatedAt), -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw VoiceprintDatabaseError.stepFailed(lastError(database))
        }
    }

    private func openDatabase() throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            let message = database.map { lastError($0) } ?? "unknown"
            if let database {
                sqlite3_close(database)
            }
            throw VoiceprintDatabaseError.openFailed(message)
        }
        return database
    }

    private func migrate(_ database: OpaquePointer?) throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS voiceprints (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                voiceprint TEXT NOT NULL,
                role TEXT NOT NULL,
                confidence TEXT NOT NULL,
                embedding_json TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            database: database
        )
        try exec("CREATE INDEX IF NOT EXISTS idx_voiceprints_updated_at ON voiceprints(updated_at)", database: database)
    }

    private func exec(_ sql: String, database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw VoiceprintDatabaseError.stepFailed(lastError(database))
        }
    }

    private func prepare(_ sql: String, database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VoiceprintDatabaseError.prepareFailed(lastError(database))
        }
        return statement
    }

    private func lastError(_ database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else { return "unknown" }
        return String(cString: message)
    }

    private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func isoString(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func date(from text: String?) -> Date? {
        guard let text else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
