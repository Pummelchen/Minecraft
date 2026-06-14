import Foundation

public enum ClientCredentialProvider {
    private static let tokenEnvironmentKey = "PUMMELCHEN_CLIENT_API_TOKEN"
    private static let tokenInfoPlistKey = "PummelchenClientAPIToken"
    private static let tokenResourceName = "client-api-token"

    public static func defaultClientAPIToken() -> String? {
        clientAPIToken(
            environmentToken: ProcessInfo.processInfo.environment[tokenEnvironmentKey],
            infoPlistToken: Bundle.main.object(forInfoDictionaryKey: tokenInfoPlistKey) as? String,
            resourceURLs: [Bundle.main.url(forResource: tokenResourceName, withExtension: nil), executableResourceURL()]
        )
    }

    static func clientAPIToken(environmentToken: String?, infoPlistToken: String?, resourceURLs: [URL?]) -> String? {
        if let token = clean(environmentToken) {
            return token
        }
        if let token = clean(infoPlistToken) {
            return token
        }
        for url in resourceURLs {
            if let url, let token = tokenFromFile(url) {
                return token
            }
        }
        return nil
    }

    private static func executableResourceURL() -> URL? {
        guard let executable = Bundle.main.executableURL else {
            return nil
        }
        return executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(tokenResourceName)
    }

    private static func tokenFromFile(_ url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return clean(raw)
    }

    private static func clean(_ token: String?) -> String? {
        let value = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
