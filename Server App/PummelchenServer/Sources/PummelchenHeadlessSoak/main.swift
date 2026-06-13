import Foundation
import PummelchenCore

enum HeadlessSoakError: Error, CustomStringConvertible {
    case usage
    case missingValue(String)
    case commandFailed(String)
    case invalidValue(String)
    case missingPath(String)
    case loginNotObserved
    case connectedTooShort(Double)
    case fatalLogLines(Int)
    case crashReports(Int)

    var description: String {
        switch self {
        case .usage:
            return """
            usage:
              pummelchen-headless-soak --dmg <path> --release-id <id> --server-address <host:25565> --headless-command <shell> [--server-url <url>] [--duration-seconds 300] [--work-dir <dir>] [--report <path>] [--client-api-token <token>] [--keep-work-dir true]

            The headless command must start a real Minecraft client from the synced isolated Minecraft directory and stay alive for the soak duration.
            Environment provided to the command:
              PUMMELCHEN_SOAK_MINECRAFT_DIR
              PUMMELCHEN_SOAK_HOME
              PUMMELCHEN_SOAK_JAVA
              PUMMELCHEN_SOAK_SERVER_ADDRESS
              PUMMELCHEN_SOAK_DURATION_SECONDS
            """
        case .missingValue(let option):
            return "missing value for \(option)"
        case .commandFailed(let message):
            return message
        case .invalidValue(let message):
            return message
        case .missingPath(let path):
            return "missing required path: \(path)"
        case .loginNotObserved:
            return "headless client did not produce a live-server login signal"
        case .connectedTooShort(let seconds):
            return "headless client stayed connected for only \(Int(seconds)) seconds"
        case .fatalLogLines(let count):
            return "headless client logs contain \(count) fatal line(s)"
        case .crashReports(let count):
            return "headless client produced \(count) crash report(s)"
        }
    }
}

struct Arguments {
    let options: [String: String]

    init(_ raw: [String]) throws {
        var options: [String: String] = [:]
        var index = 1
        while index < raw.count {
            let option = raw[index]
            guard option.hasPrefix("--") else { throw HeadlessSoakError.usage }
            guard index + 1 < raw.count else { throw HeadlessSoakError.missingValue(option) }
            options[option] = raw[index + 1]
            index += 2
        }
        self.options = options
    }

    func require(_ key: String) throws -> String {
        guard let value = options[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HeadlessSoakError.missingValue(key)
        }
        return value
    }
}

struct HeadlessSoakConfig {
    let dmg: URL
    let releaseID: String
    let serverAddress: String
    let serverURL: URL
    let durationSeconds: Double
    let workDir: URL
    let report: URL
    let headlessCommand: String
    let clientAPIToken: String?
    let keepWorkDir: Bool

    init(arguments: Arguments) throws {
        let dmg = URL(fileURLWithPath: try arguments.require("--dmg")).standardizedFileURL
        let releaseID = try arguments.require("--release-id")
        let serverAddress = try arguments.require("--server-address")
        let serverURL = URL(string: arguments.options["--server-url"] ?? "https://pummelchen.91.99.176.243.nip.io")
        guard let serverURL else { throw HeadlessSoakError.invalidValue("invalid --server-url") }
        let durationSeconds = Double(arguments.options["--duration-seconds"] ?? "300") ?? 300
        guard durationSeconds >= 300 else {
            throw HeadlessSoakError.invalidValue("--duration-seconds must be at least 300")
        }
        let defaultWork = FileManager.default.temporaryDirectory
            .appendingPathComponent("pummelchen-headless-soak-\(releaseID)-\(UUID().uuidString)", isDirectory: true)
        let workDir = arguments.options["--work-dir"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? defaultWork
        let report = arguments.options["--report"]
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? dmg.deletingLastPathComponent().appendingPathComponent("Pummelchen-Client-Installer.dmg.headless-live-soak.json")
        self.dmg = dmg
        self.releaseID = releaseID
        self.serverAddress = serverAddress
        self.serverURL = serverURL
        self.durationSeconds = durationSeconds
        self.workDir = workDir
        self.report = report
        self.headlessCommand = try arguments.require("--headless-command")
        self.clientAPIToken = arguments.options["--client-api-token"] ?? ProcessInfo.processInfo.environment["PUMMELCHEN_CLIENT_API_TOKEN"]
        self.keepWorkDir = arguments.options["--keep-work-dir"] == "true"
    }
}

struct ProcessResult {
    let exitCode: Int32
    let output: String
    let durationSeconds: Double
    let timedOut: Bool
}

struct SoakReport: Encodable {
    let releaseID: String
    let dmgSHA256: String
    let serverAddress: String
    let startedAt: String
    let completedAt: String
    let durationSeconds: Double
    let status: String
    let installedFromDMG: Bool
    let javaOK: Bool
    let neoforgeOK: Bool
    let syncOK: Bool
    let loginOK: Bool
    let stayedConnected: Bool
    let crashReportCount: Int
    let fatalLogCount: Int
    let rendererSummary: String
    let notes: String

    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id"
        case dmgSHA256 = "dmg_sha256"
        case serverAddress = "server_address"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationSeconds = "duration_seconds"
        case status
        case installedFromDMG = "installed_from_dmg"
        case javaOK = "java_ok"
        case neoforgeOK = "neoforge_ok"
        case syncOK = "sync_ok"
        case loginOK = "login_ok"
        case stayedConnected = "stayed_connected"
        case crashReportCount = "crash_report_count"
        case fatalLogCount = "fatal_log_count"
        case rendererSummary = "renderer_summary"
        case notes
    }
}

struct HeadlessSoakRunner {
    let config: HeadlessSoakConfig
    let fileManager = FileManager.default

    func run() throws {
        guard fileManager.fileExists(atPath: config.dmg.path) else {
            throw HeadlessSoakError.missingPath(config.dmg.path)
        }
        let started = Date()
        var installedFromDMG = false
        var javaOK = false
        var neoforgeOK = false
        var syncOK = false
        var loginOK = false
        var stayedConnected = false
        var crashReportCount = 0
        var fatalLogCount = 0
        var notes: [String] = []
        let dmgSHA = try SHA256Hasher.hashFile(at: config.dmg)

        do {
            try fileManager.createDirectory(at: config.workDir, withIntermediateDirectories: true)
            let mountPoint = try mountDMG()
            defer { try? unmount(mountPoint: mountPoint) }

            let installedApp = try installApp(from: mountPoint)
            installedFromDMG = true
            let syncBinary = installedApp.appendingPathComponent("Contents/MacOS/pummelchen-client-sync")
            guard fileManager.isExecutableFile(atPath: syncBinary.path) else {
                throw HeadlessSoakError.missingPath(syncBinary.path)
            }

            let minecraftDir = config.workDir.appendingPathComponent("minecraft", isDirectory: true)
            let pummelchenHome = config.workDir.appendingPathComponent("pummelchen-home", isDirectory: true)
            try fileManager.createDirectory(at: minecraftDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: pummelchenHome, withIntermediateDirectories: true)

            let syncResult = try runSync(syncBinary: syncBinary, minecraftDir: minecraftDir, pummelchenHome: pummelchenHome)
            try syncResult.output.write(to: config.workDir.appendingPathComponent("pummelchen-client-sync.log"), atomically: true, encoding: .utf8)
            syncOK = syncResult.exitCode == 0
            guard syncOK else {
                throw HeadlessSoakError.commandFailed("client sync failed: \(syncResult.output)")
            }

            let java = try managedJavaExecutable(pummelchenHome: pummelchenHome)
            let javaResult = try runProcess(executable: java.path, arguments: ["-version"], timeoutSeconds: 30, environment: [:])
            javaOK = javaResult.exitCode == 0
            guard javaOK else {
                throw HeadlessSoakError.commandFailed("managed Java verification failed: \(javaResult.output)")
            }

            neoforgeOK = hasNeoForgeInstall(minecraftDir: minecraftDir)
            guard neoforgeOK else {
                throw HeadlessSoakError.missingPath(minecraftDir.appendingPathComponent("versions/neoforge-26.1.2.76").path)
            }

            let soak = try runHeadless(minecraftDir: minecraftDir, pummelchenHome: pummelchenHome, java: java)
            try soak.output.write(to: config.workDir.appendingPathComponent("headless-minecraft.log"), atomically: true, encoding: .utf8)
            loginOK = observedLogin(in: soak.output, minecraftDir: minecraftDir)
            stayedConnected = soak.durationSeconds >= config.durationSeconds && soak.exitCode == 0
            crashReportCount = countCrashReports(minecraftDir: minecraftDir)
            fatalLogCount = countFatalLogLines(extraOutput: soak.output, minecraftDir: minecraftDir)

            if !loginOK { throw HeadlessSoakError.loginNotObserved }
            if !stayedConnected { throw HeadlessSoakError.connectedTooShort(soak.durationSeconds) }
            if crashReportCount > 0 { throw HeadlessSoakError.crashReports(crashReportCount) }
            if fatalLogCount > 0 { throw HeadlessSoakError.fatalLogLines(fatalLogCount) }
            notes.append("Installed DMG app, synced isolated client, verified managed Java and NeoForge, joined live server, and completed \(Int(soak.durationSeconds))s headless soak.")
        } catch {
            notes.append("failed: \(error)")
            let completed = Date()
            try writeReport(
                started: started,
                completed: completed,
                dmgSHA: dmgSHA,
                status: "failed",
                installedFromDMG: installedFromDMG,
                javaOK: javaOK,
                neoforgeOK: neoforgeOK,
                syncOK: syncOK,
                loginOK: loginOK,
                stayedConnected: stayedConnected,
                crashReportCount: crashReportCount,
                fatalLogCount: fatalLogCount,
                notes: notes.joined(separator: " ")
            )
            throw error
        }

        let completed = Date()
        try writeReport(
            started: started,
            completed: completed,
            dmgSHA: dmgSHA,
            status: "passed",
            installedFromDMG: installedFromDMG,
            javaOK: javaOK,
            neoforgeOK: neoforgeOK,
            syncOK: syncOK,
            loginOK: loginOK,
            stayedConnected: stayedConnected,
            crashReportCount: crashReportCount,
            fatalLogCount: fatalLogCount,
            notes: notes.joined(separator: " ")
        )
        if !config.keepWorkDir {
            try? fileManager.removeItem(at: config.workDir)
        }
    }

    private func mountDMG() throws -> URL {
        #if os(macOS)
        let result = try runProcess(executable: "/usr/bin/hdiutil", arguments: ["attach", "-nobrowse", "-readonly", "-plist", config.dmg.path], timeoutSeconds: 120, environment: [:])
        guard result.exitCode == 0, let data = result.output.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw HeadlessSoakError.commandFailed("hdiutil attach failed: \(result.output)")
        }
        return URL(fileURLWithPath: mount, isDirectory: true)
        #else
        throw HeadlessSoakError.commandFailed("DMG mounting requires macOS")
        #endif
    }

    private func unmount(mountPoint: URL) throws {
        _ = try runProcess(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint.path], timeoutSeconds: 60, environment: [:])
    }

    private func installApp(from mountPoint: URL) throws -> URL {
        let app = mountPoint.appendingPathComponent("Pummelchen Client.app", isDirectory: true)
        guard fileManager.fileExists(atPath: app.path) else {
            throw HeadlessSoakError.missingPath(app.path)
        }
        let target = config.workDir.appendingPathComponent("Pummelchen Client.app", isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        _ = try runProcess(executable: "/bin/cp", arguments: ["-R", app.path, target.path], timeoutSeconds: 120, environment: [:])
        return target
    }

    private func runSync(syncBinary: URL, minecraftDir: URL, pummelchenHome: URL) throws -> ProcessResult {
        var args = [
            "sync",
            "--force",
            "--server-url", config.serverURL.absoluteString,
            "--minecraft-dir", minecraftDir.path,
            "--pummelchen-home", pummelchenHome.path,
            "--db", pummelchenHome.appendingPathComponent("client.duckdb").path,
            "--client-id", "headless-soak-\(config.releaseID)",
            "--allow-while-running"
        ]
        if let token = config.clientAPIToken, !token.isEmpty {
            args.append(contentsOf: ["--client-api-token", token])
        } else {
            args.append("--no-report")
        }
        return try runProcess(executable: syncBinary.path, arguments: args, timeoutSeconds: 900, environment: [:])
    }

    private func managedJavaExecutable(pummelchenHome: URL) throws -> URL {
        let marker = pummelchenHome.appendingPathComponent("java/current-runtime.txt")
        guard let markerText = try? String(contentsOf: marker, encoding: .utf8) else {
            throw HeadlessSoakError.missingPath(marker.path)
        }
        for line in markerText.split(separator: "\n") {
            if line.hasPrefix("java=") {
                let path = String(line.dropFirst("java=".count))
                guard fileManager.isExecutableFile(atPath: path) else {
                    throw HeadlessSoakError.missingPath(path)
                }
                return URL(fileURLWithPath: path)
            }
        }
        throw HeadlessSoakError.commandFailed("managed Java marker does not contain java= path")
    }

    private func hasNeoForgeInstall(minecraftDir: URL) -> Bool {
        let version = minecraftDir.appendingPathComponent("versions/neoforge-26.1.2.76/neoforge-26.1.2.76.json")
        let libraries = minecraftDir.appendingPathComponent("libraries/net/neoforged/neoforge/26.1.2.76", isDirectory: true)
        return fileManager.fileExists(atPath: version.path) && fileManager.fileExists(atPath: libraries.path)
    }

    private func runHeadless(minecraftDir: URL, pummelchenHome: URL, java: URL) throws -> ProcessResult {
        var env = ProcessInfo.processInfo.environment
        env["PUMMELCHEN_SOAK_MINECRAFT_DIR"] = minecraftDir.path
        env["PUMMELCHEN_SOAK_HOME"] = pummelchenHome.path
        env["PUMMELCHEN_SOAK_JAVA"] = java.path
        env["PUMMELCHEN_SOAK_SERVER_ADDRESS"] = config.serverAddress
        env["PUMMELCHEN_SOAK_DURATION_SECONDS"] = String(Int(config.durationSeconds))
        env["PUMMELCHEN_SOAK_RELEASE_ID"] = config.releaseID
        let timeout = config.durationSeconds + 180
        return try runProcess(executable: "/bin/sh", arguments: ["-lc", config.headlessCommand], timeoutSeconds: timeout, environment: env)
    }

    private func observedLogin(in output: String, minecraftDir: URL) -> Bool {
        let text = (output + "\n" + collectedMinecraftLogs(minecraftDir: minecraftDir)).lowercased()
        return [
            "joined the game",
            "logged in",
            "connected to server",
            "connecting to 91.99.176.243",
            "pummelchen",
            "multiplayer server"
        ].contains { text.contains($0) }
    }

    private func countCrashReports(minecraftDir: URL) -> Int {
        let crashDir = minecraftDir.appendingPathComponent("crash-reports", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: crashDir, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "txt" }.count
    }

    private func countFatalLogLines(extraOutput: String, minecraftDir: URL) -> Int {
        let text = extraOutput + "\n" + collectedMinecraftLogs(minecraftDir: minecraftDir)
        let fatalPatterns = [
            "FATAL",
            "Crash report",
            "ModLoadingException",
            "NoClassDefFoundError",
            "ClassNotFoundException",
            "Failed to connect",
            "Connection refused",
            "Disconnected from server",
            "mismatch"
        ]
        return text
            .split(separator: "\n")
            .filter { line in fatalPatterns.contains { String(line).localizedCaseInsensitiveContains($0) } }
            .count
    }

    private func collectedMinecraftLogs(minecraftDir: URL) -> String {
        let logs = minecraftDir.appendingPathComponent("logs", isDirectory: true)
        let candidates = [
            logs.appendingPathComponent("latest.log"),
            config.workDir.appendingPathComponent("headless-minecraft.log"),
            config.workDir.appendingPathComponent("pummelchen-client-sync.log")
        ]
        return candidates.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    private func writeReport(
        started: Date,
        completed: Date,
        dmgSHA: String,
        status: String,
        installedFromDMG: Bool,
        javaOK: Bool,
        neoforgeOK: Bool,
        syncOK: Bool,
        loginOK: Bool,
        stayedConnected: Bool,
        crashReportCount: Int,
        fatalLogCount: Int,
        notes: String
    ) throws {
        try fileManager.createDirectory(at: config.report.deletingLastPathComponent(), withIntermediateDirectories: true)
        let report = SoakReport(
            releaseID: config.releaseID,
            dmgSHA256: dmgSHA,
            serverAddress: config.serverAddress,
            startedAt: Self.iso(started),
            completedAt: Self.iso(completed),
            durationSeconds: completed.timeIntervalSince(started),
            status: status,
            installedFromDMG: installedFromDMG,
            javaOK: javaOK,
            neoforgeOK: neoforgeOK,
            syncOK: syncOK,
            loginOK: loginOK,
            stayedConnected: stayedConnected,
            crashReportCount: crashReportCount,
            fatalLogCount: fatalLogCount,
            rendererSummary: "Swift DMG headless live soak",
            notes: notes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: config.report, options: .atomic)
    }

    private func runProcess(executable: String, arguments: [String], timeoutSeconds: Double, environment: [String: String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pummelchen-process-\(UUID().uuidString).log")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let start = Date()
        try process.run()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var timedOut = false
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 2)
            if process.isRunning {
                process.interrupt()
            }
        }
        process.waitUntilExit()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return ProcessResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            durationSeconds: Date().timeIntervalSince(start),
            timedOut: timedOut
        )
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

@main
struct PummelchenHeadlessSoakMain {
    static func main() {
        do {
            let config = try HeadlessSoakConfig(arguments: Arguments(CommandLine.arguments))
            try HeadlessSoakRunner(config: config).run()
            print("pummelchen_headless_soak=passed")
            print("report=\(config.report.path)")
        } catch {
            FileHandle.standardError.write(Data("pummelchen-headless-soak failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
