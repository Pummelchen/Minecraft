import Foundation

public struct ClientSyncManifestEntry: Equatable, Sendable {
    public let section: String
    public let name: String
    public let sizeBytes: Int64
    public let sha256: String
    public let urlPath: String

    public init(section: String, name: String, sizeBytes: Int64, sha256: String, urlPath: String) {
        self.section = section
        self.name = name
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.urlPath = urlPath
    }
}

public struct ClientSyncManifest: Equatable, Sendable {
    public let entries: [ClientSyncManifestEntry]

    public init(entries: [ClientSyncManifestEntry]) {
        self.entries = entries
    }
}

public enum ClientSyncManifestParser {
    private static let allowedSections: Set<String> = [
        "mods",
        "resourcepacks",
        "shaderpacks",
        "tools"
    ]

    public static func parse(_ text: String) throws -> ClientSyncManifest {
        var entries: [ClientSyncManifestEntry] = []
        var seenKeys = Set<String>()

        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            try ContractValidation.require(
                columns.count == 5,
                "line \(lineNumber): expected 5 tab-separated columns"
            )

            let section = columns[0]
            let name = columns[1]
            let sizeText = columns[2]
            let shaText = columns[3]
            let urlPath = columns[4]

            try ContractValidation.require(
                allowedSections.contains(section),
                "line \(lineNumber): unknown section \(section)"
            )
            try ContractValidation.require(!name.isEmpty, "line \(lineNumber): name is required")
            try validateManifestFileName(name, lineNumber: lineNumber)
            guard let sizeBytes = Int64(sizeText), sizeBytes >= 0 else {
                throw ContractValidationError.invalid("line \(lineNumber): size must be a non-negative integer")
            }
            try ContractValidation.require(
                shaText.hasPrefix("sha256:"),
                "line \(lineNumber): sha256 must use sha256:<hex> format"
            )
            let sha256 = String(shaText.dropFirst("sha256:".count))
            try ContractValidation.requireSHA256(sha256, field: "line \(lineNumber) sha256")
            try ContractValidation.require(
                urlPath.hasPrefix("downloads/releases/"),
                "line \(lineNumber): url_path must be release-scoped"
            )
            try validateManifestURLPath(urlPath, section: section, name: name, lineNumber: lineNumber)

            let key = "\(section)\t\(name)"
            try ContractValidation.require(
                seenKeys.insert(key).inserted,
                "line \(lineNumber): duplicate manifest entry \(section)/\(name)"
            )

            entries.append(
                ClientSyncManifestEntry(
                    section: section,
                    name: name,
                    sizeBytes: sizeBytes,
                    sha256: sha256,
                    urlPath: urlPath
                )
            )
        }

        return ClientSyncManifest(entries: entries)
    }

    private static func validateManifestFileName(_ name: String, lineNumber: Int) throws {
        let forbidden = CharacterSet(charactersIn: "/\\")
        try ContractValidation.require(name.rangeOfCharacter(from: forbidden) == nil, "line \(lineNumber): name must be a plain file name")
        try ContractValidation.require(name != "." && name != ".." && !name.hasPrefix("."), "line \(lineNumber): hidden or relative file names are not allowed")
        try ContractValidation.require(!name.contains("\0"), "line \(lineNumber): name contains a NUL byte")
    }

    private static func validateManifestURLPath(_ urlPath: String, section: String, name: String, lineNumber: Int) throws {
        try ContractValidation.require(!urlPath.contains(".."), "line \(lineNumber): url_path must not contain parent traversal")
        try ContractValidation.require(!urlPath.contains("\\"), "line \(lineNumber): url_path must use forward slashes")
        try ContractValidation.require(
            urlPath.hasSuffix("/client-files/\(section)/\(name)"),
            "line \(lineNumber): url_path must match the manifest section and file name"
        )
    }
}
