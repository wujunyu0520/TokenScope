import SQLite3
import XCTest
@testable import TokenScopeCore

final class OpenCodeSQLiteUsageTests: XCTestCase {
    func testOpenCodeScannerReadsSQLiteMessagesWithoutSubtractingCacheRead() throws {
        let root = try makeOpenCodeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("opencode.db")
        try makeDatabase(at: dbURL)
        try insertSession(
            dbURL,
            id: "ses-longcat",
            directory: "/tmp/longcat",
            title: "LongCat work",
            modelJSON: #"{"id":"LongCat-2.0","providerID":"longcat","variant":"default"}"#,
            created: 1_800_000_000_000,
            updated: 1_800_000_010_000
        )
        try insertAssistantMessage(
            dbURL,
            id: "msg-longcat",
            sessionID: "ses-longcat",
            time: 1_800_000_002_000,
            providerID: "longcat",
            modelID: "LongCat-2.0",
            input: 1_000,
            output: 200,
            reasoning: 30,
            cacheRead: 700,
            cacheWrite: 40,
            cost: 0.12
        )

        let results = OpenCodeScanner(storageRoot: root).scan()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].session.provider, .openCode)
        XCTAssertEqual(results[0].session.modelsUsed, ["LongCat-2.0"])
        XCTAssertEqual(results[0].session.totalUsage.inputTokens, 1_000)
        XCTAssertEqual(results[0].session.totalUsage.outputTokens, 230)
        XCTAssertEqual(results[0].session.totalUsage.cacheReadTokens, 700)
        XCTAssertEqual(results[0].session.totalUsage.cacheCreationTokens, 40)
        XCTAssertEqual(results[0].usageRecords.first?.accountId, "longcat")
    }

    func testOpenCodeUsageProviderBuildsModelBreakdowns() async throws {
        let root = try makeOpenCodeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("opencode.db")
        try makeDatabase(at: dbURL)
        try insertSession(
            dbURL,
            id: "ses-longcat",
            directory: "/tmp/longcat",
            title: "LongCat work",
            modelJSON: #"{"id":"LongCat-2.0","providerID":"longcat","variant":"default"}"#,
            created: 1_800_000_000_000,
            updated: 1_800_000_010_000
        )
        try insertSession(
            dbURL,
            id: "ses-kimi",
            directory: "/tmp/kimi",
            title: "Kimi work",
            modelJSON: #"{"id":"k2p7","providerID":"kimi-for-coding","variant":"default"}"#,
            created: 1_799_999_900_000,
            updated: 1_799_999_910_000
        )
        try insertAssistantMessage(
            dbURL,
            id: "msg-longcat",
            sessionID: "ses-longcat",
            time: 1_800_000_002_000,
            providerID: "longcat",
            modelID: "LongCat-2.0",
            input: 1_000,
            output: 200,
            reasoning: 30,
            cacheRead: 700,
            cacheWrite: 40,
            cost: 0.12
        )
        try insertAssistantMessage(
            dbURL,
            id: "msg-kimi",
            sessionID: "ses-kimi",
            time: 1_799_999_902_000,
            providerID: "kimi-for-coding",
            modelID: "k2p7",
            input: 300,
            output: 20,
            reasoning: 0,
            cacheRead: 900,
            cacheWrite: 0,
            cost: 0
        )

        let scanned = OpenCodeScanner(storageRoot: root).scan()
        let snapshot = try await OpenCodeUsageProvider(
            sessions: scanned.map(\.session),
            usageRecords: scanned.flatMap(\.usageRecords),
            databaseURL: dbURL,
            now: Date(timeIntervalSince1970: 1_800_000_020)
        ).fetchSnapshot()

        XCTAssertEqual(snapshot.provider, .openCode)
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows.first?.tokenUsage?.cacheReadTokens, 1_600)
        XCTAssertEqual(snapshot.modelBreakdowns.map(\.groupName), ["LongCat", "Kimi"])
        XCTAssertEqual(snapshot.modelBreakdowns[0].inputTokens, 1_000)
        XCTAssertEqual(snapshot.modelBreakdowns[0].outputTokens, 200)
        XCTAssertEqual(snapshot.modelBreakdowns[0].reasoningTokens, 30)
        XCTAssertEqual(snapshot.modelBreakdowns[0].cacheReadTokens, 700)
        XCTAssertEqual(snapshot.modelBreakdowns[0].pricingCoverage, .priced)
        XCTAssertEqual(snapshot.modelBreakdowns[0].estimatedCostUSD, 0.001469, accuracy: 0.000000001)
    }

    private func makeOpenCodeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDatabase(at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try exec(
            db,
            """
            CREATE TABLE session (
              id TEXT PRIMARY KEY,
              directory TEXT NOT NULL,
              title TEXT NOT NULL,
              model TEXT,
              cost REAL DEFAULT 0 NOT NULL,
              tokens_input INTEGER DEFAULT 0 NOT NULL,
              tokens_output INTEGER DEFAULT 0 NOT NULL,
              tokens_reasoning INTEGER DEFAULT 0 NOT NULL,
              tokens_cache_read INTEGER DEFAULT 0 NOT NULL,
              tokens_cache_write INTEGER DEFAULT 0 NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL
            );
            CREATE TABLE message (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL,
              data TEXT NOT NULL
            );
            """
        )
    }

    private func insertSession(
        _ dbURL: URL,
        id: String,
        directory: String,
        title: String,
        modelJSON: String,
        created: Int64,
        updated: Int64
    ) throws {
        try withDatabase(dbURL) { db in
            let sql = """
            INSERT INTO session (
              id, directory, title, model, time_created, time_updated
            ) VALUES (?, ?, ?, ?, ?, ?)
            """
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, directory, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, modelJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 5, created)
            sqlite3_bind_int64(statement, 6, updated)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

    private func insertAssistantMessage(
        _ dbURL: URL,
        id: String,
        sessionID: String,
        time: Int64,
        providerID: String,
        modelID: String,
        input: Int,
        output: Int,
        reasoning: Int,
        cacheRead: Int,
        cacheWrite: Int,
        cost: Double
    ) throws {
        let data = """
        {"role":"assistant","cost":\(cost),"tokens":{"input":\(input),"output":\(output),"reasoning":\(reasoning),"cache":{"read":\(cacheRead),"write":\(cacheWrite)}},"modelID":"\(modelID)","providerID":"\(providerID)","time":{"created":\(time),"completed":\(time + 1)}}
        """
        try withDatabase(dbURL) { db in
            let sql = "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)"
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, sessionID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 3, time)
            sqlite3_bind_int64(statement, 4, time + 1)
            sqlite3_bind_text(statement, 5, data, -1, SQLITE_TRANSIENT)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }

    private func withDatabase(_ url: URL, _ body: (OpaquePointer?) throws -> Void) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try body(db)
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        if result != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            XCTFail(message)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
