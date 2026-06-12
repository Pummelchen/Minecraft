import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PummelchenCore

public struct ClientHTTPRetryPolicy: Equatable, Sendable {
    public let maxAttempts: Int
    public let requestTimeoutSeconds: TimeInterval
    public let baseDelayNanoseconds: UInt64

    public init(
        maxAttempts: Int = 4,
        requestTimeoutSeconds: TimeInterval = 300,
        baseDelayNanoseconds: UInt64 = 700_000_000
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.baseDelayNanoseconds = baseDelayNanoseconds
    }
}

public enum ClientHTTPError: Error, CustomStringConvertible {
    case httpStatus(Int, URL)
    case emptyDownload(URL)

    public var description: String {
        switch self {
        case .httpStatus(let status, let url):
            return "HTTP \(status) for \(url.absoluteString)"
        case .emptyDownload(let url):
            return "empty download from \(url.absoluteString)"
        }
    }
}

public struct ClientHTTPClient: Sendable {
    public let retryPolicy: ClientHTTPRetryPolicy
    private let session: URLSession

    public init(retryPolicy: ClientHTTPRetryPolicy = ClientHTTPRetryPolicy()) {
        self.retryPolicy = retryPolicy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = retryPolicy.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = max(retryPolicy.requestTimeoutSeconds, 900)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func data(from url: URL, headers: [String: String] = [:]) async throws -> Data {
        try await retrying {
            var request = URLRequest(url: url, timeoutInterval: retryPolicy.requestTimeoutSeconds)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (data, response) = try await session.data(for: request)
            try Self.requireSuccess(response: response, url: url)
            return data
        }
    }

    public func download(from url: URL, headers: [String: String] = [:]) async throws -> URL {
        try await retrying {
            var request = URLRequest(url: url, timeoutInterval: retryPolicy.requestTimeoutSeconds)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let (file, response) = try await session.download(for: request)
            try Self.requireSuccess(response: response, url: url)
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                throw ClientHTTPError.emptyDownload(url)
            }
            return file
        }
    }

    public func send(_ request: URLRequest) async throws -> Data {
        try await retrying {
            var next = request
            next.timeoutInterval = retryPolicy.requestTimeoutSeconds
            let (data, response) = try await session.data(for: next)
            try Self.requireSuccess(response: response, url: next.url ?? URL(fileURLWithPath: "/"))
            return data
        }
    }

    private func retrying<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...retryPolicy.maxAttempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt >= retryPolicy.maxAttempts || !Self.isRetryable(error) {
                    throw error
                }
                let multiplier = UInt64(1 << min(attempt - 1, 4))
                try await Task.sleep(nanoseconds: retryPolicy.baseDelayNanoseconds * multiplier)
            }
        }
        throw lastError ?? ContractValidationError.invalid("HTTP request failed without an error")
    }

    private static func requireSuccess(response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientHTTPError.httpStatus(http.statusCode, url)
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case ClientHTTPError.httpStatus(let status, _) = error {
            return status == 408 || status == 429 || (500..<600).contains(status)
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return [
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorInternationalRoamingOff,
                NSURLErrorCallIsActive,
                NSURLErrorDataNotAllowed,
                NSURLErrorSecureConnectionFailed
            ].contains(ns.code)
        }
        return false
    }
}
