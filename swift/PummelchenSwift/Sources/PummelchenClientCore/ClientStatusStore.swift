import Foundation
import PummelchenCore

public struct ClientStatusStore: Sendable {
    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func initialize() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("""
        CREATE TABLE IF NOT EXISTS client_state (
          key VARCHAR PRIMARY KEY,
          value VARCHAR NOT NULL,
          updated_at TIMESTAMP NOT NULL
        );
        CREATE TABLE IF NOT EXISTS release_history (
          release_id VARCHAR PRIMARY KEY,
          first_seen_at TIMESTAMP NOT NULL,
          installed_at TIMESTAMP,
          status VARCHAR NOT NULL,
          manifest_sha256 VARCHAR
        );
        CREATE TABLE IF NOT EXISTS sync_runs (
          run_id VARCHAR PRIMARY KEY,
          started_at TIMESTAMP NOT NULL,
          finished_at TIMESTAMP,
          from_release_id VARCHAR,
          target_release_id VARCHAR,
          result VARCHAR NOT NULL,
          files_verified INTEGER,
          files_downloaded INTEGER,
          files_quarantined INTEGER,
          error_message VARCHAR
        );
        CREATE TABLE IF NOT EXISTS client_defaults (
          key VARCHAR PRIMARY KEY,
          desired_value VARCHAR NOT NULL,
          applied_value VARCHAR,
          applied_at TIMESTAMP,
          status VARCHAR NOT NULL,
          source VARCHAR NOT NULL
        );
        """)
    }

    public func record(snapshot: ClientStatusSnapshot) throws {
        try initialize()
        let now = Self.duckTimestamp(Date())
        let runID = UUID().uuidString
        var statements: [String] = []
        statements.append(upsertState("server_url", snapshot.serverURL, now: now))
        statements.append(upsertState("sync_state", snapshot.state.rawValue, now: now))
        statements.append(upsertState("last_check", snapshot.checkedAt, now: now))
        statements.append(upsertState("minecraft_directory", snapshot.minecraftDirectory, now: now))
        if let serverRelease = snapshot.serverReleaseID {
            statements.append(upsertState("server_release_id", serverRelease, now: now))
            statements.append("""
            INSERT INTO release_history(release_id, first_seen_at, installed_at, status, manifest_sha256)
            VALUES ('\(Self.sql(serverRelease))', TIMESTAMP '\(now)', NULL, 'server_seen', NULL)
            ON CONFLICT(release_id) DO UPDATE SET status = excluded.status;
            """)
        }
        if let localRelease = snapshot.localReleaseID {
            statements.append(upsertState("local_release_id", localRelease, now: now))
        }
        statements.append("""
        INSERT INTO sync_runs(
          run_id, started_at, finished_at, from_release_id, target_release_id, result,
          files_verified, files_downloaded, files_quarantined, error_message
        )
        VALUES (
          '\(Self.sql(runID))',
          TIMESTAMP '\(now)',
          TIMESTAMP '\(now)',
          \(Self.sqlLiteral(snapshot.localReleaseID)),
          \(Self.sqlLiteral(snapshot.serverReleaseID)),
          '\(Self.sql(snapshot.state.rawValue))',
          0,
          0,
          0,
          \(Self.sqlLiteral(snapshot.errorMessage))
        );
        """)
        for row in snapshot.defaultsHealth {
            statements.append("""
            INSERT INTO client_defaults(key, desired_value, applied_value, applied_at, status, source)
            VALUES (
              '\(Self.sql(row.id))',
              '\(Self.sql(row.desiredValue))',
              '\(Self.sql(row.observedValue))',
              TIMESTAMP '\(now)',
              '\(Self.sql(row.status.rawValue))',
              '\(Self.sql(row.source))'
            )
            ON CONFLICT(key) DO UPDATE SET
              desired_value = excluded.desired_value,
              applied_value = excluded.applied_value,
              applied_at = excluded.applied_at,
              status = excluded.status,
              source = excluded.source;
            """)
        }
        try execute(statements.joined(separator: "\n"))
    }

    private func upsertState(_ key: String, _ value: String, now: String) -> String {
        """
        INSERT INTO client_state(key, value, updated_at)
        VALUES ('\(Self.sql(key))', '\(Self.sql(value))', TIMESTAMP '\(now)')
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
        """
    }

    private func execute(_ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.duckDBExecutablePath())
        process.arguments = [databaseURL.path, "-c", sql]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ContractValidationError.invalid("duckdb write failed: \(output)")
        }
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(sql(value))'"
    }

    private static func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func duckDBExecutablePath() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/duckdb",
            "/usr/local/bin/duckdb",
            "/usr/bin/duckdb",
            "/bin/duckdb"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-lc", "command -v duckdb"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0, !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
            return output
        }
        throw ContractValidationError.invalid("duckdb executable not found; install DuckDB or bundle it with the client app")
    }

    private static func duckTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
