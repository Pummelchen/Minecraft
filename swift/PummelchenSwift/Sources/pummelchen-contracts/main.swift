import Foundation
import PummelchenCore

enum CommandError: Error, CustomStringConvertible {
    case usage
    case unsupported(String)

    var description: String {
        switch self {
        case .usage:
            return """
            Usage:
              pummelchen-contracts validate-manifest <client-sync-manifest.tsv>
              pummelchen-contracts validate-current-release <current-release.json>
            """
        case .unsupported(let command):
            return "unsupported command: \(command)"
        }
    }
}

func readFile(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

func run(arguments: [String]) throws {
    guard arguments.count == 3 else {
        throw CommandError.usage
    }

    let command = arguments[1]
    let path = arguments[2]

    switch command {
    case "validate-manifest":
        let text = String(decoding: try readFile(path), as: UTF8.self)
        let manifest = try ClientSyncManifestParser.parse(text)
        print("manifest_valid=true entries=\(manifest.entries.count)")
    case "validate-current-release":
        let release = try CurrentReleaseValidator.decode(try readFile(path))
        try CurrentReleaseValidator.validate(release)
        print("current_release_valid=true release_id=\(release.releaseID)")
    default:
        throw CommandError.unsupported(command)
    }
}

do {
    try run(arguments: CommandLine.arguments)
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
