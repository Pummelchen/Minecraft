import Foundation

public struct APIEnvelope<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let ok: Bool
    public let generatedAt: String
    public let payload: Payload

    enum CodingKeys: String, CodingKey {
        case ok
        case generatedAt = "generated_at"
        case payload
    }

    public init(ok: Bool, generatedAt: String, payload: Payload) {
        self.ok = ok
        self.generatedAt = generatedAt
        self.payload = payload
    }
}

public struct ClientStatusReport: Codable, Equatable, Sendable {
    public let clientID: String
    public let releaseID: String
    public let checkedAt: String
    public let verifiedFiles: Int
    public let changedFiles: Int
    public let message: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case releaseID = "release_id"
        case checkedAt = "checked_at"
        case verifiedFiles = "verified_files"
        case changedFiles = "changed_files"
        case message
    }

    public init(clientID: String, releaseID: String, checkedAt: String, verifiedFiles: Int, changedFiles: Int, message: String) {
        self.clientID = clientID
        self.releaseID = releaseID
        self.checkedAt = checkedAt
        self.verifiedFiles = verifiedFiles
        self.changedFiles = changedFiles
        self.message = message
    }
}

public struct ReleaseHistoryEntry: Codable, Equatable, Sendable {
    public let releaseID: String
    public let status: String
    public let createdAt: String
    public let activatedAt: String?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id"
        case status
        case createdAt = "created_at"
        case activatedAt = "activated_at"
        case notes
    }

    public init(releaseID: String, status: String, createdAt: String, activatedAt: String?, notes: String?) {
        self.releaseID = releaseID
        self.status = status
        self.createdAt = createdAt
        self.activatedAt = activatedAt
        self.notes = notes
    }
}

public struct TestedUpdateRow: Codable, Equatable, Sendable {
    public let testedAt: String
    public let testedAtDisplay: String
    public let title: String
    public let eventType: String
    public let source: String
    public let status: String
    public let oldFile: String?
    public let newFile: String?
    public let version: String?
    public let sourceURL: String?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case testedAt = "tested_at"
        case testedAtDisplay = "tested_at_display"
        case title
        case eventType = "event_type"
        case source
        case status
        case oldFile = "old_file"
        case newFile = "new_file"
        case version
        case sourceURL = "source_url"
        case notes
    }
}

public struct FailedModRow: Codable, Equatable, Sendable {
    public let failedAt: String
    public let failedAtDisplay: String
    public let title: String
    public let sourceURL: String?
    public let filename: String?
    public let version: String?
    public let failureReason: String
    public let details: String

    enum CodingKeys: String, CodingKey {
        case failedAt = "failed_at"
        case failedAtDisplay = "failed_at_display"
        case title
        case sourceURL = "source_url"
        case filename
        case version
        case failureReason = "failure_reason"
        case details
    }
}
