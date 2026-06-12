import Foundation

public struct MinecraftClientDefaults: Equatable, Sendable {
    public let shaderPack: String
    public let resourcePacks: [String]
    public let irisProperties: [String: String]
    public let configProperties: [String: [String: String]]

    public init(
        shaderPack: String = "BSL_v10.1.3.zip",
        resourcePacks: [String] = [
            "vanilla",
            "mod_resources",
            "file/ModernArch v2.8.2 [26.1] [128x].zip",
            "file/ModernArch FA Extension v2.2.zip",
            "file/ModernArch Denser Grass Addon.zip"
        ],
        irisProperties: [String: String] = [
            "shaderPack": "BSL_v10.1.3.zip",
            "enableShaders": "true",
            "allowUnknownShaders": "false",
            "colorSpace": "SRGB",
            "disableUpdateMessage": "false",
            "enableDebugOptions": "false",
            "maxShadowRenderDistance": "32"
        ],
        configProperties: [String: [String: String]] = [
            "config/neoforge-client.toml": ["showLoadWarnings": "false"],
            "config/forge-client.toml": ["showLoadWarnings": "false"],
            "config/yuushya-client.toml": ["showCheckScreen": "false"],
            "config/untitledduckmod-server.toml": [
                "duck_tamed_no_follow": "true",
                "goose_tamed_no_follow": "true"
            ]
        ]
    ) {
        self.shaderPack = shaderPack
        self.resourcePacks = resourcePacks
        self.irisProperties = irisProperties
        self.configProperties = configProperties
    }
}

public enum MinecraftClientDefaultWriter {
    public static func apply(defaults: MinecraftClientDefaults = MinecraftClientDefaults(), to minecraftDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: minecraftDirectory.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )

        let resourcePackValue = minecraftStringArray(defaults.resourcePacks)
        try setColonValue(
            path: minecraftDirectory.appendingPathComponent("options.txt"),
            key: "resourcePacks",
            value: resourcePackValue
        )
        try setColonValue(
            path: minecraftDirectory.appendingPathComponent("options.txt"),
            key: "incompatibleResourcePacks",
            value: "[]"
        )
        try setEqualsValue(
            path: minecraftDirectory.appendingPathComponent("optionsshaders.txt"),
            key: "shaderPack",
            value: defaults.shaderPack
        )
        for (key, value) in defaults.irisProperties {
            try setEqualsValue(
                path: minecraftDirectory.appendingPathComponent("config/iris.properties"),
                key: key,
                value: value
            )
        }
        for (relativePath, values) in defaults.configProperties {
            for (key, value) in values {
                try setEqualsValue(
                    path: minecraftDirectory.appendingPathComponent(relativePath),
                    key: key,
                    value: value
                )
            }
        }
    }

    private static func setColonValue(path: URL, key: String, value: String) throws {
        try setLine(path: path, key: key, separator: ":", value: value)
    }

    private static func setEqualsValue(path: URL, key: String, value: String) throws {
        try setLine(path: path, key: key, separator: "=", value: value)
    }

    private static func minecraftStringArray(_ values: [String]) -> String {
        "[\(values.map { "\"\(escapeMinecraftString($0))\"" }.joined(separator: ","))]"
    }

    private static func escapeMinecraftString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func setLine(path: URL, key: String, separator: String, value: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let prefix = key + separator
        var replaced = false
        var output: [String] = []

        for line in existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) {
                if !replaced {
                    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                    output.append("\(indent)\(key)\(separator)\(value)")
                    replaced = true
                }
            } else {
                output.append(line)
            }
        }
        if !replaced {
            output.append("\(key)\(separator)\(value)")
        }
        try output.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }
}
