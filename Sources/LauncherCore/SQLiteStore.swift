import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteConfiguration: Equatable, Sendable {
    public var journalMode: String
    public var foreignKeysEnabled: Bool

    public init(journalMode: String, foreignKeysEnabled: Bool) {
        self.journalMode = journalMode
        self.foreignKeysEnabled = foreignKeysEnabled
    }
}

public struct StoredSessionRecord: Equatable, Sendable {
    public var record: SessionRecord
    public var storeRevision: Int

    public init(record: SessionRecord, storeRevision: Int) {
        self.record = record
        self.storeRevision = storeRevision
    }
}

public enum SQLiteStoreError: LocalizedError, Equatable {
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case unsupportedSchema(Int)
    case invalidStoredData(String)
    case validation(String)
    case notFound(entity: String, id: String)
    case duplicateProjectDirectory(String)
    case duplicateLauncherName(String)
    case staleRevision(entity: String, expected: Int, actual: Int)
    case immutableField(String)
    case projectHasLaunchers(UUID)
    case launcherHasActiveSessions(UUID)
    case primarySessionAlreadyActive(UUID)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Could not open launcher database: \(message)"
        case .sqlite(_, let message):
            return "Launcher database error: \(message)"
        case .unsupportedSchema(let version):
            return "Launcher database schema \(version) is newer than this application supports."
        case .invalidStoredData(let message):
            return "Launcher database contains invalid data: \(message)"
        case .validation(let message):
            return message
        case .notFound(let entity, let id):
            return "\(entity.capitalized) was not found: \(id)"
        case .duplicateProjectDirectory(let directory):
            return "A launcher project already exists for \(directory)."
        case .duplicateLauncherName(let name):
            return "A launcher named “\(name)” already exists."
        case .staleRevision(let entity, let expected, let actual):
            return "Stale \(entity) revision \(expected); the current revision is \(actual)."
        case .immutableField(let field):
            return "\(field) cannot be changed."
        case .projectHasLaunchers:
            return "Delete the project's launchers before deleting the project."
        case .launcherHasActiveSessions:
            return "Close active sessions before deleting the launcher."
        case .primarySessionAlreadyActive:
            return "The launcher already has an active primary session."
        }
    }
}

/// The durable source of truth used by the daemon. The connection is serialized by a lock,
/// while SQLite's WAL mode permits independent readers in the GUI and diagnostic tools.
public final class SQLiteStore: @unchecked Sendable {
    public let databaseURL: URL

    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = LauncherJSON.encoder()
    private let decoder = LauncherJSON.decoder()

    public init(databaseURL: URL = LauncherPaths.databaseURL) throws {
        self.databaseURL = databaseURL.standardizedFileURL
        try LauncherPaths.ensurePrivateDirectory(self.databaseURL.deletingLastPathComponent())

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(self.databaseURL.path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite returned \(result)"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteStoreError.openFailed(message)
        }
        database = handle
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5_000)

        do {
            try configureAndMigrate()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.databaseURL.path)
        } catch {
            sqlite3_close_v2(handle)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    public func configuration() throws -> SQLiteConfiguration {
        try locked {
            let journalMode = try scalarText("PRAGMA journal_mode") ?? ""
            let foreignKeys = try scalarInt("PRAGMA foreign_keys") == 1
            return SQLiteConfiguration(journalMode: journalMode.lowercased(), foreignKeysEnabled: foreignKeys)
        }
    }

    // MARK: - Projects

    @discardableResult
    public func createProject(_ proposed: ProjectRecord) throws -> ProjectRecord {
        try locked {
            let canonical = try LauncherValidation.canonicalDirectory(proposed.directory)
            guard FileManager.default.isWritableFile(atPath: canonical) else {
                throw LauncherValidationError.invalidDirectory(canonical)
            }
            let displayName = proposed.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty else {
                throw SQLiteStoreError.validation("Project display name must contain non-whitespace text.")
            }

            var project = proposed
            project.displayName = displayName
            project.directory = canonical
            project.revision = 1
            project.manifestHash = nil
            project.manifestSyncState = .pending

            return try transaction {
                if try projectRecord(directory: canonical, includeDeleted: false) != nil {
                    throw SQLiteStoreError.duplicateProjectDirectory(canonical)
                }
                do {
                    try execute(
                        "INSERT INTO projects (id, canonical_directory, revision, record_json, deleted_at) VALUES (?, ?, ?, ?, NULL)",
                        [.text(project.id.uuidString), .text(canonical), .integer(1), .blob(try encode(project))]
                    )
                } catch let error as SQLiteStoreError where error.isConstraint {
                    throw SQLiteStoreError.duplicateProjectDirectory(canonical)
                }
                return project
            }
        }
    }

    public func project(id: UUID) throws -> ProjectRecord? {
        try locked { try projectRecord(id: id, includeDeleted: false) }
    }

    public func project(directory: String) throws -> ProjectRecord? {
        try locked {
            let canonical = try LauncherValidation.canonicalDirectory(directory, mustExist: false)
            return try projectRecord(directory: canonical, includeDeleted: false)
        }
    }

    public func listProjects() throws -> [ProjectRecord] {
        try locked {
            try queryRecords(
                "SELECT record_json FROM projects WHERE deleted_at IS NULL ORDER BY canonical_directory, id",
                bindings: [],
                as: ProjectRecord.self
            )
        }
    }

    @discardableResult
    public func updateProject(_ proposed: ProjectRecord, expectedRevision: Int) throws -> ProjectRecord {
        try locked {
            try transaction {
                guard let current = try projectRecord(id: proposed.id, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "project", id: proposed.id.uuidString)
                }
                try requireRevision(entity: "project", expected: expectedRevision, actual: current.revision)

                let canonical = try LauncherValidation.canonicalDirectory(proposed.directory)
                guard FileManager.default.isWritableFile(atPath: canonical) else {
                    throw LauncherValidationError.invalidDirectory(canonical)
                }
                let displayName = proposed.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayName.isEmpty else {
                    throw SQLiteStoreError.validation("Project display name must contain non-whitespace text.")
                }
                if let duplicate = try projectRecord(directory: canonical, includeDeleted: false), duplicate.id != current.id {
                    throw SQLiteStoreError.duplicateProjectDirectory(canonical)
                }

                if current.displayName == displayName, current.directory == canonical {
                    return current
                }

                var updated = current
                updated.displayName = displayName
                updated.directory = canonical
                updated.revision += 1
                updated.manifestHash = nil
                updated.manifestSyncState = .pending
                updated.updatedAt = Date()
                try updateProjectRow(updated, expectedRevision: current.revision)
                return updated
            }
        }
    }

    public func deleteProject(id: UUID, expectedRevision: Int) throws {
        try locked {
            try transaction {
                guard let current = try projectRecord(id: id, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "project", id: id.uuidString)
                }
                try requireRevision(entity: "project", expected: expectedRevision, actual: current.revision)
                let count = try scalarInt(
                    "SELECT COUNT(*) FROM launchers WHERE project_id = ? AND deleted_at IS NULL",
                    bindings: [.text(id.uuidString)]
                )
                guard count == 0 else { throw SQLiteStoreError.projectHasLaunchers(id) }
                try execute(
                    "UPDATE projects SET deleted_at = ?, revision = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL",
                    [.double(Date().timeIntervalSince1970), .integer(Int64(current.revision + 1)), .text(id.uuidString), .integer(Int64(current.revision))]
                )
                try ensureChanged(entity: "project", id: id.uuidString)
            }
        }
    }

    // MARK: - Launchers

    @discardableResult
    public func createLauncher(_ proposed: LauncherRecord) throws -> LauncherRecord {
        try locked {
            try transaction {
                guard let project = try projectRecord(id: proposed.projectID, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "project", id: proposed.projectID.uuidString)
                }
                var launcher = try normalizedLauncher(proposed, project: project)
                launcher.revision = 1

                if try launcherRecord(normalizedName: launcher.normalizedName, includeDeleted: false) != nil {
                    throw SQLiteStoreError.duplicateLauncherName(launcher.name)
                }
                do {
                    try execute(
                        "INSERT INTO launchers (id, project_id, normalized_name, revision, record_json, deleted_at) VALUES (?, ?, ?, ?, ?, NULL)",
                        [
                            .text(launcher.id.uuidString), .text(launcher.projectID.uuidString),
                            .text(launcher.normalizedName), .integer(1), .blob(try encode(launcher))
                        ]
                    )
                } catch let error as SQLiteStoreError where error.isConstraint {
                    throw SQLiteStoreError.duplicateLauncherName(launcher.name)
                }
                try markProjectPending(project)
                return launcher
            }
        }
    }

    public func launcher(id: UUID) throws -> LauncherRecord? {
        try locked { try launcherRecord(id: id, includeDeleted: false) }
    }

    public func launcher(named name: String) throws -> LauncherRecord? {
        try locked {
            try launcherRecord(normalizedName: LauncherValidation.normalizeName(name), includeDeleted: false)
        }
    }

    public func listLaunchers(projectID: UUID? = nil, query: String? = nil) throws -> [LauncherRecord] {
        try locked {
            let sql: String
            let bindings: [SQLValue]
            if let projectID {
                sql = "SELECT record_json FROM launchers WHERE deleted_at IS NULL AND project_id = ? ORDER BY normalized_name, id"
                bindings = [.text(projectID.uuidString)]
            } else {
                sql = "SELECT record_json FROM launchers WHERE deleted_at IS NULL ORDER BY normalized_name, id"
                bindings = []
            }
            var records = try queryRecords(sql, bindings: bindings, as: LauncherRecord.self)
            if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let needle = LauncherValidation.normalizeName(query)
                records = records.filter {
                    $0.normalizedName.contains(needle) ||
                        LauncherValidation.normalizeName($0.description).contains(needle) ||
                        $0.tags.contains(where: { LauncherValidation.normalizeName($0).contains(needle) })
                }
            }
            return records
        }
    }

    @discardableResult
    public func updateLauncher(_ proposed: LauncherRecord, expectedRevision: Int) throws -> LauncherRecord {
        try locked {
            try transaction {
                guard let current = try launcherRecord(id: proposed.id, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "launcher", id: proposed.id.uuidString)
                }
                try requireRevision(entity: "launcher", expected: expectedRevision, actual: current.revision)
                guard proposed.projectID == current.projectID else {
                    throw SQLiteStoreError.immutableField("Launcher project")
                }
                guard let project = try projectRecord(id: current.projectID, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "project", id: current.projectID.uuidString)
                }

                var updated = try normalizedLauncher(proposed, project: project)
                if let duplicate = try launcherRecord(normalizedName: updated.normalizedName, includeDeleted: false), duplicate.id != current.id {
                    throw SQLiteStoreError.duplicateLauncherName(updated.name)
                }
                updated.revision = current.revision + 1
                updated.createdAt = current.createdAt
                updated.updatedAt = Date()

                do {
                    try execute(
                        "UPDATE launchers SET normalized_name = ?, revision = ?, record_json = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL",
                        [
                            .text(updated.normalizedName), .integer(Int64(updated.revision)), .blob(try encode(updated)),
                            .text(updated.id.uuidString), .integer(Int64(current.revision))
                        ]
                    )
                } catch let error as SQLiteStoreError where error.isConstraint {
                    throw SQLiteStoreError.duplicateLauncherName(updated.name)
                }
                try ensureChanged(entity: "launcher", id: updated.id.uuidString)
                try markProjectPending(project)
                return updated
            }
        }
    }

    public func deleteLauncher(id: UUID, expectedRevision: Int) throws {
        try locked {
            try transaction {
                guard let current = try launcherRecord(id: id, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "launcher", id: id.uuidString)
                }
                try requireRevision(entity: "launcher", expected: expectedRevision, actual: current.revision)
                let activeStates = [SessionState.starting, .running, .partial, .stopping].map(\.rawValue)
                let placeholders = activeStates.map { _ in "?" }.joined(separator: ",")
                let activeCount = try scalarInt(
                    "SELECT COUNT(*) FROM sessions WHERE launcher_id = ? AND state IN (\(placeholders))",
                    bindings: [.text(id.uuidString)] + activeStates.map(SQLValue.text)
                )
                guard activeCount == 0 else { throw SQLiteStoreError.launcherHasActiveSessions(id) }

                try execute(
                    "UPDATE launchers SET deleted_at = ?, revision = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL",
                    [.double(Date().timeIntervalSince1970), .integer(Int64(current.revision + 1)), .text(id.uuidString), .integer(Int64(current.revision))]
                )
                try ensureChanged(entity: "launcher", id: id.uuidString)
                guard let project = try projectRecord(id: current.projectID, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "project", id: current.projectID.uuidString)
                }
                try markProjectPending(project)
            }
        }
    }

    public func launcherDetail(id: UUID) throws -> LauncherDetail? {
        try locked {
            guard let launcher = try launcherRecord(id: id, includeDeleted: false),
                  let project = try projectRecord(id: launcher.projectID, includeDeleted: false) else { return nil }
            let activeSessions = try sessionRecords(launcherID: launcher.id, activeOnly: true).map(\.record)
            let compatibilityActive = activeSessions.first(where: { $0.launchRole == .primary })
                ?? activeSessions.first
            return LauncherDetail(
                project: project,
                launcher: launcher,
                activeSession: compatibilityActive,
                activeSessions: activeSessions,
                lastSession: try latestSessionRecord(launcherID: launcher.id)?.record
            )
        }
    }

    public func launcherDetails(query: String? = nil) throws -> [LauncherDetail] {
        let launchers = try listLaunchers(query: query)
        return try launchers.compactMap { try launcherDetail(id: $0.id) }
    }

    // MARK: - Sessions

    @discardableResult
    public func createSession(_ proposed: SessionRecord) throws -> StoredSessionRecord {
        try locked {
            try transaction {
                guard let launcher = try launcherRecord(id: proposed.launcherID, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "launcher", id: proposed.launcherID.uuidString)
                }
                guard proposed.launcherRevision == launcher.revision else {
                    throw SQLiteStoreError.staleRevision(
                        entity: "launcher", expected: proposed.launcherRevision, actual: launcher.revision
                    )
                }
                var session = proposed
                session.launcherName = launcher.name
                if session.projectSnapshot == nil,
                   let project = try projectRecord(id: launcher.projectID, includeDeleted: true) {
                    session.projectSnapshot = SessionProjectSnapshot(project: project)
                }
                do {
                    try execute(
                        "INSERT INTO sessions (id, launcher_id, revision, state, launch_role, started_at, updated_at, record_json) VALUES (?, ?, 1, ?, ?, ?, ?, ?)",
                        [
                            .text(session.id.uuidString), .text(session.launcherID.uuidString),
                            .text(session.state.rawValue), .text(session.launchRole.rawValue),
                            .double(session.startedAt.timeIntervalSince1970), .double(Date().timeIntervalSince1970),
                            .blob(try encode(session))
                        ]
                    )
                } catch let error as SQLiteStoreError where error.isConstraint {
                    if session.launchRole == .primary,
                       try hasActivePrimarySession(launcherID: session.launcherID) {
                        throw SQLiteStoreError.primarySessionAlreadyActive(session.launcherID)
                    }
                    throw error
                }
                return StoredSessionRecord(record: session, storeRevision: 1)
            }
        }
    }

    public func session(id: UUID) throws -> StoredSessionRecord? {
        try locked { try sessionRecord(id: id) }
    }

    public func listSessions(launcherID: UUID? = nil, activeOnly: Bool = false) throws -> [StoredSessionRecord] {
        try locked { try sessionRecords(launcherID: launcherID, activeOnly: activeOnly) }
    }

    @discardableResult
    public func updateSession(_ proposed: SessionRecord, expectedRevision: Int) throws -> StoredSessionRecord {
        try locked {
            try transaction {
                guard let current = try sessionRecord(id: proposed.id) else {
                    throw SQLiteStoreError.notFound(entity: "session", id: proposed.id.uuidString)
                }
                try requireRevision(entity: "session", expected: expectedRevision, actual: current.storeRevision)
                guard proposed.launcherID == current.record.launcherID else {
                    throw SQLiteStoreError.immutableField("Session launcher")
                }
                guard proposed.launcherRevision == current.record.launcherRevision else {
                    throw SQLiteStoreError.immutableField("Session launcher revision")
                }
                guard proposed.launchRole == current.record.launchRole else {
                    throw SQLiteStoreError.immutableField("Session launch role")
                }
                guard proposed.projectSnapshot == current.record.projectSnapshot else {
                    throw SQLiteStoreError.immutableField("Session project snapshot")
                }
                guard proposed.runtimeArguments == current.record.runtimeArguments else {
                    throw SQLiteStoreError.immutableField("Session runtime arguments")
                }
                guard proposed.actionSnapshots == current.record.actionSnapshots else {
                    throw SQLiteStoreError.immutableField("Session action snapshots")
                }

                var updated = proposed
                updated.launcherName = current.record.launcherName
                updated.startedAt = current.record.startedAt
                let nextRevision = current.storeRevision + 1
                do {
                    try execute(
                        "UPDATE sessions SET revision = ?, state = ?, updated_at = ?, record_json = ? WHERE id = ? AND revision = ?",
                        [
                            .integer(Int64(nextRevision)), .text(updated.state.rawValue), .double(Date().timeIntervalSince1970),
                            .blob(try encode(updated)), .text(updated.id.uuidString), .integer(Int64(current.storeRevision))
                        ]
                    )
                } catch let error as SQLiteStoreError where error.isConstraint {
                    if updated.launchRole == .primary,
                       try hasActivePrimarySession(launcherID: updated.launcherID, excluding: updated.id) {
                        throw SQLiteStoreError.primarySessionAlreadyActive(updated.launcherID)
                    }
                    throw error
                }
                try ensureChanged(entity: "session", id: updated.id.uuidString)
                return StoredSessionRecord(record: updated, storeRevision: nextRevision)
            }
        }
    }

    public func sessionHistory(
        launcherID: UUID? = nil,
        state: SessionState? = nil,
        role: SessionLaunchRole? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) throws -> SessionHistoryPage {
        try locked {
            guard (1...200).contains(limit) else {
                throw SQLiteStoreError.validation("History limit must be between 1 and 200.")
            }
            let decodedCursor = try cursor.map(decodeHistoryCursor)
            var clauses: [String] = []
            var bindings: [SQLValue] = []
            if let launcherID {
                clauses.append("launcher_id = ?")
                bindings.append(.text(launcherID.uuidString))
            }
            if let state {
                clauses.append("state = ?")
                bindings.append(.text(state.rawValue))
            }
            if let role {
                clauses.append("launch_role = ?")
                bindings.append(.text(role.rawValue))
            }
            if let decodedCursor {
                clauses.append("(started_at < ? OR (started_at = ? AND id < ?))")
                bindings.append(.double(decodedCursor.startedAt))
                bindings.append(.double(decodedCursor.startedAt))
                bindings.append(.text(decodedCursor.id.uuidString))
            }
            let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
            bindings.append(.integer(Int64(limit + 1)))
            let statement = try prepare(
                "SELECT record_json, started_at FROM sessions\(whereClause) ORDER BY started_at DESC, id DESC LIMIT ?"
            )
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            var rows: [(record: SessionRecord, startedAt: Double)] = []
            historyRows: while rows.count <= limit {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    rows.append((
                        record: try decode(columnData(statement, index: 0)),
                        startedAt: sqlite3_column_double(statement, 1)
                    ))
                case SQLITE_DONE:
                    break historyRows
                default:
                    throw currentSQLiteError()
                }
            }
            let hasMore = rows.count > limit
            if hasMore { rows.removeLast(rows.count - limit) }
            let nextCursor = hasMore ? rows.last.map {
                encodeHistoryCursor(HistoryCursor(startedAt: $0.startedAt, id: $0.record.id))
            } : nil
            return SessionHistoryPage(sessions: rows.map(\.record), nextCursor: nextCursor)
        }
    }

    public func deleteSession(id: UUID, expectedRevision: Int) throws {
        try locked {
            try transaction {
                guard let current = try sessionRecord(id: id) else {
                    throw SQLiteStoreError.notFound(entity: "session", id: id.uuidString)
                }
                try requireRevision(entity: "session", expected: expectedRevision, actual: current.storeRevision)
                try execute("DELETE FROM sessions WHERE id = ? AND revision = ?", [.text(id.uuidString), .integer(Int64(expectedRevision))])
                try ensureChanged(entity: "session", id: id.uuidString)
            }
        }
    }

    // MARK: - Manifest synchronization

    public func checkManifest(projectID: UUID, renderer: MarkdownRenderer = MarkdownRenderer()) throws -> SyncResult {
        try locked {
            try transaction {
                guard let project = try projectRecord(id: projectID, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "project", id: projectID.uuidString)
                }
                let launchers = try launcherRecords(projectID: projectID)
                let inspection = try renderer.check(project: project, launchers: launchers)
                var updated = project
                updated.manifestHash = inspection.expectedHash
                updated.manifestSyncState = inspection.inSync ? .synced : .drifted
                try updateProjectMetadata(updated)
                return SyncResult(
                    project: updated,
                    path: inspection.path,
                    inSync: inspection.inSync,
                    repaired: false,
                    expectedHash: inspection.expectedHash,
                    actualHash: inspection.actualHash,
                    message: inspection.message
                )
            }
        }
    }

    public func repairManifest(projectID: UUID, renderer: MarkdownRenderer = MarkdownRenderer()) throws -> SyncResult {
        try locked {
            try transaction {
                guard let project = try projectRecord(id: projectID, includeDeleted: false) else {
                    throw SQLiteStoreError.notFound(entity: "project", id: projectID.uuidString)
                }
                let launchers = try launcherRecords(projectID: projectID)
                let rendered = try renderer.write(project: project, launchers: launchers)
                var updated = project
                updated.manifestHash = rendered.fileSHA256
                updated.manifestSyncState = .synced
                try updateProjectMetadata(updated)
                return SyncResult(
                    project: updated,
                    path: rendered.fileURL.path,
                    inSync: true,
                    repaired: true,
                    expectedHash: rendered.fileSHA256,
                    actualHash: rendered.fileSHA256,
                    message: "launch_details.md is synchronized."
                )
            }
        }
    }

    // MARK: - Schema and SQL helpers

    private func configureAndMigrate() throws {
        try executeScript("PRAGMA journal_mode=WAL")
        try executeScript("PRAGMA foreign_keys=ON")
        try executeScript("PRAGMA synchronous=NORMAL")

        let version = Int(try scalarInt("PRAGMA user_version"))
        guard version <= LauncherSchema.version else { throw SQLiteStoreError.unsupportedSchema(version) }
        if version == 0 {
            try transaction {
                try executeScript(
                    """
                    CREATE TABLE IF NOT EXISTS projects (
                        id TEXT PRIMARY KEY NOT NULL,
                        canonical_directory TEXT NOT NULL,
                        revision INTEGER NOT NULL CHECK (revision > 0),
                        record_json BLOB NOT NULL,
                        deleted_at REAL
                    );
                    CREATE UNIQUE INDEX IF NOT EXISTS projects_active_directory
                        ON projects(canonical_directory) WHERE deleted_at IS NULL;

                    CREATE TABLE IF NOT EXISTS launchers (
                        id TEXT PRIMARY KEY NOT NULL,
                        project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE RESTRICT,
                        normalized_name TEXT NOT NULL,
                        revision INTEGER NOT NULL CHECK (revision > 0),
                        record_json BLOB NOT NULL,
                        deleted_at REAL
                    );
                    CREATE UNIQUE INDEX IF NOT EXISTS launchers_active_name
                        ON launchers(normalized_name) WHERE deleted_at IS NULL;
                    CREATE INDEX IF NOT EXISTS launchers_project ON launchers(project_id, deleted_at);

                    CREATE TABLE IF NOT EXISTS sessions (
                        id TEXT PRIMARY KEY NOT NULL,
                        launcher_id TEXT NOT NULL REFERENCES launchers(id) ON DELETE RESTRICT,
                        revision INTEGER NOT NULL CHECK (revision > 0),
                        state TEXT NOT NULL,
                        launch_role TEXT NOT NULL DEFAULT 'primary'
                            CHECK (launch_role IN ('primary', 'additional')),
                        started_at REAL NOT NULL,
                        updated_at REAL NOT NULL,
                        record_json BLOB NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS sessions_launcher_started
                        ON sessions(launcher_id, started_at DESC, id DESC);
                    CREATE INDEX IF NOT EXISTS sessions_state ON sessions(state);
                    CREATE INDEX IF NOT EXISTS sessions_history_cursor
                        ON sessions(started_at DESC, id DESC);
                    CREATE UNIQUE INDEX IF NOT EXISTS sessions_one_active_primary
                        ON sessions(launcher_id)
                        WHERE launch_role = 'primary'
                          AND state IN ('starting', 'running', 'partial', 'stopping');
                    """
                )
                try executeScript("PRAGMA user_version = \(LauncherSchema.version)")
            }
        } else if version == 1 {
            try transaction {
                let activeStates = [SessionState.starting, .running, .partial, .stopping].map(\.rawValue)
                let placeholders = activeStates.map { _ in "?" }.joined(separator: ",")
                if let duplicateLauncherID = try scalarText(
                    """
                    SELECT launcher_id
                    FROM sessions
                    WHERE state IN (\(placeholders))
                    GROUP BY launcher_id
                    HAVING COUNT(*) > 1
                    LIMIT 1
                    """,
                    bindings: activeStates.map(SQLValue.text)
                ) {
                    throw SQLiteStoreError.invalidStoredData(
                        "schema migration found multiple active legacy sessions for launcher \(duplicateLauncherID); no process ownership was changed"
                    )
                }
                try executeScript(
                    "ALTER TABLE sessions ADD COLUMN launch_role TEXT NOT NULL DEFAULT 'primary' "
                        + "CHECK (launch_role IN ('primary', 'additional'))"
                )
                try executeScript("DROP INDEX IF EXISTS sessions_launcher_started")
                try executeScript(
                    """
                    CREATE INDEX sessions_launcher_started
                        ON sessions(launcher_id, started_at DESC, id DESC);
                    CREATE INDEX IF NOT EXISTS sessions_history_cursor
                        ON sessions(started_at DESC, id DESC);
                    CREATE UNIQUE INDEX sessions_one_active_primary
                        ON sessions(launcher_id)
                        WHERE launch_role = 'primary'
                          AND state IN ('starting', 'running', 'partial', 'stopping');
                    """
                )
                try executeScript("PRAGMA user_version = \(LauncherSchema.version)")
            }
        }
    }

    private func normalizedLauncher(_ proposed: LauncherRecord, project: ProjectRecord) throws -> LauncherRecord {
        var launcher = proposed
        let validated = try LauncherValidation.validatedName(launcher.name)
        launcher.name = validated.display
        launcher.normalizedName = validated.normalized
        launcher.tags = LauncherValidation.normalizedTags(launcher.tags)
        launcher.actions = try launcher.actions.map { action in
            var normalized = action
            let actionName = try LauncherValidation.validatedName(action.name, allowReserved: true)
            normalized.name = actionName.display
            normalized.normalizedName = actionName.normalized
            return normalized
        }
        try LauncherValidation.validateLauncher(launcher, project: project)
        return launcher
    }

    private func markProjectPending(_ project: ProjectRecord) throws {
        var updated = project
        updated.revision += 1
        updated.manifestHash = nil
        updated.manifestSyncState = .pending
        updated.updatedAt = Date()
        try updateProjectRow(updated, expectedRevision: project.revision)
    }

    private func updateProjectRow(_ project: ProjectRecord, expectedRevision: Int) throws {
        do {
            try execute(
                "UPDATE projects SET canonical_directory = ?, revision = ?, record_json = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL",
                [
                    .text(project.directory), .integer(Int64(project.revision)), .blob(try encode(project)),
                    .text(project.id.uuidString), .integer(Int64(expectedRevision))
                ]
            )
        } catch let error as SQLiteStoreError where error.isConstraint {
            throw SQLiteStoreError.duplicateProjectDirectory(project.directory)
        }
        try ensureChanged(entity: "project", id: project.id.uuidString)
    }

    private func updateProjectMetadata(_ project: ProjectRecord) throws {
        try execute(
            "UPDATE projects SET record_json = ? WHERE id = ? AND revision = ? AND deleted_at IS NULL",
            [.blob(try encode(project)), .text(project.id.uuidString), .integer(Int64(project.revision))]
        )
        try ensureChanged(entity: "project", id: project.id.uuidString)
    }

    private func projectRecord(id: UUID, includeDeleted: Bool) throws -> ProjectRecord? {
        let deletedClause = includeDeleted ? "" : " AND deleted_at IS NULL"
        return try queryRecord(
            "SELECT record_json FROM projects WHERE id = ?\(deletedClause) LIMIT 1",
            bindings: [.text(id.uuidString)],
            as: ProjectRecord.self
        )
    }

    private func projectRecord(directory: String, includeDeleted: Bool) throws -> ProjectRecord? {
        let deletedClause = includeDeleted ? "" : " AND deleted_at IS NULL"
        return try queryRecord(
            "SELECT record_json FROM projects WHERE canonical_directory = ?\(deletedClause) ORDER BY deleted_at IS NULL DESC LIMIT 1",
            bindings: [.text(directory)],
            as: ProjectRecord.self
        )
    }

    private func launcherRecord(id: UUID, includeDeleted: Bool) throws -> LauncherRecord? {
        let deletedClause = includeDeleted ? "" : " AND deleted_at IS NULL"
        return try queryRecord(
            "SELECT record_json FROM launchers WHERE id = ?\(deletedClause) LIMIT 1",
            bindings: [.text(id.uuidString)],
            as: LauncherRecord.self
        )
    }

    private func launcherRecord(normalizedName: String, includeDeleted: Bool) throws -> LauncherRecord? {
        let deletedClause = includeDeleted ? "" : " AND deleted_at IS NULL"
        return try queryRecord(
            "SELECT record_json FROM launchers WHERE normalized_name = ?\(deletedClause) ORDER BY deleted_at IS NULL DESC LIMIT 1",
            bindings: [.text(normalizedName)],
            as: LauncherRecord.self
        )
    }

    private func launcherRecords(projectID: UUID) throws -> [LauncherRecord] {
        try queryRecords(
            "SELECT record_json FROM launchers WHERE project_id = ? AND deleted_at IS NULL ORDER BY normalized_name, id",
            bindings: [.text(projectID.uuidString)],
            as: LauncherRecord.self
        )
    }

    private func sessionRecord(id: UUID) throws -> StoredSessionRecord? {
        let statement = try prepare("SELECT record_json, revision FROM sessions WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        try bind([.text(id.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let record: SessionRecord = try decode(columnData(statement, index: 0))
            return StoredSessionRecord(record: record, storeRevision: Int(sqlite3_column_int64(statement, 1)))
        case SQLITE_DONE:
            return nil
        default:
            throw currentSQLiteError()
        }
    }

    private func latestSessionRecord(launcherID: UUID) throws -> StoredSessionRecord? {
        let statement = try prepare(
            "SELECT record_json, revision FROM sessions WHERE launcher_id = ? ORDER BY started_at DESC, id DESC LIMIT 1"
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(launcherID.uuidString)], to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            let record: SessionRecord = try decode(columnData(statement, index: 0))
            return StoredSessionRecord(record: record, storeRevision: Int(sqlite3_column_int64(statement, 1)))
        case SQLITE_DONE:
            return nil
        default:
            throw currentSQLiteError()
        }
    }

    private func hasActivePrimarySession(launcherID: UUID, excluding sessionID: UUID? = nil) throws -> Bool {
        let states = [SessionState.starting, .running, .partial, .stopping].map(\.rawValue)
        var bindings: [SQLValue] = [.text(launcherID.uuidString), .text(SessionLaunchRole.primary.rawValue)]
            + states.map(SQLValue.text)
        var exclusion = ""
        if let sessionID {
            exclusion = " AND id != ?"
            bindings.append(.text(sessionID.uuidString))
        }
        let placeholders = states.map { _ in "?" }.joined(separator: ",")
        return try scalarInt(
            "SELECT COUNT(*) FROM sessions WHERE launcher_id = ? AND launch_role = ? AND state IN (\(placeholders))\(exclusion)",
            bindings: bindings
        ) > 0
    }

    private func sessionRecords(launcherID: UUID?, activeOnly: Bool) throws -> [StoredSessionRecord] {
        var clauses: [String] = []
        var bindings: [SQLValue] = []
        if let launcherID {
            clauses.append("launcher_id = ?")
            bindings.append(.text(launcherID.uuidString))
        }
        if activeOnly {
            let states = [SessionState.starting, .running, .partial, .stopping].map(\.rawValue)
            clauses.append("state IN (\(states.map { _ in "?" }.joined(separator: ",")))")
            bindings.append(contentsOf: states.map(SQLValue.text))
        }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let statement = try prepare("SELECT record_json, revision FROM sessions\(whereClause) ORDER BY started_at DESC, id DESC")
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [StoredSessionRecord] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let record: SessionRecord = try decode(columnData(statement, index: 0))
                result.append(StoredSessionRecord(record: record, storeRevision: Int(sqlite3_column_int64(statement, 1))))
            case SQLITE_DONE:
                return result
            default:
                throw currentSQLiteError()
            }
        }
    }

    private func requireRevision(entity: String, expected: Int, actual: Int) throws {
        guard expected == actual else {
            throw SQLiteStoreError.staleRevision(entity: entity, expected: expected, actual: actual)
        }
    }

    private struct HistoryCursor {
        var startedAt: Double
        var id: UUID
    }

    private func encodeHistoryCursor(_ cursor: HistoryCursor) -> String {
        let raw = String(format: "%.17g", cursor.startedAt) + "|" + cursor.id.uuidString
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodeHistoryCursor(_ value: String) throws -> HistoryCursor {
        var encoded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 { encoded += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: encoded),
              let raw = String(data: data, encoding: .utf8),
              let separator = raw.firstIndex(of: "|"),
              let startedAt = Double(raw[..<separator]),
              startedAt.isFinite,
              let id = UUID(uuidString: String(raw[raw.index(after: separator)...])) else {
            throw SQLiteStoreError.validation("History cursor is invalid or expired.")
        }
        return HistoryCursor(startedAt: startedAt, id: id)
    }

    private func ensureChanged(entity: String, id: String) throws {
        guard let database, sqlite3_changes(database) == 1 else {
            throw SQLiteStoreError.notFound(entity: entity, id: id)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try executeScript("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try executeScript("COMMIT")
            return value
        } catch {
            try? executeScript("ROLLBACK")
            throw error
        }
    }

    private enum SQLValue {
        case text(String)
        case integer(Int64)
        case double(Double)
        case blob(Data)
        case null
    }

    private func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw currentSQLiteError() }
    }

    private func executeScript(_ sql: String) throws {
        guard let database else { throw SQLiteStoreError.openFailed("connection is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorPointer)
            throw SQLiteStoreError.sqlite(code: result, message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw SQLiteStoreError.openFailed("connection is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw currentSQLiteError() }
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case .double(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw currentSQLiteError() }
        }
    }

    private func scalarInt(_ sql: String, bindings: [SQLValue] = []) throws -> Int64 {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw currentSQLiteError() }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ sql: String, bindings: [SQLValue] = []) throws -> String? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let pointer = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: pointer)
    }

    private func queryRecord<T: Decodable>(_ sql: String, bindings: [SQLValue], as type: T.Type) throws -> T? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decode(columnData(statement, index: 0), as: type)
        case SQLITE_DONE:
            return nil
        default:
            throw currentSQLiteError()
        }
    }

    private func queryRecords<T: Decodable>(_ sql: String, bindings: [SQLValue], as type: T.Type) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(try decode(columnData(statement, index: 0), as: type))
            case SQLITE_DONE:
                return result
            default:
                throw currentSQLiteError()
            }
        }
    }

    private func columnData(_ statement: OpaquePointer, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw SQLiteStoreError.invalidStoredData(error.localizedDescription) }
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type = T.self) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw SQLiteStoreError.invalidStoredData(error.localizedDescription) }
    }

    private func currentSQLiteError() -> SQLiteStoreError {
        guard let database else { return .openFailed("connection is closed") }
        return .sqlite(code: sqlite3_extended_errcode(database), message: String(cString: sqlite3_errmsg(database)))
    }
}

private extension SQLiteStoreError {
    var isConstraint: Bool {
        guard case .sqlite(let code, _) = self else { return false }
        return (code & 0xFF) == SQLITE_CONSTRAINT
    }
}
