import Foundation

public enum ShareKind: String, Codable, Sendable {
    case file
    case directory
    case symlink
}

public struct ShareItem: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let originalPath: String
    public let resolvedPath: String
    public let kind: ShareKind
    public let size: Int64
    public let modifiedAt: Date
    public let createdAt: Date
}

public struct UploadInitPayload: Codable, Sendable {
    public let fileName: String
    public let totalSize: Int64
    public let chunkSize: Int
    public let chunkCount: Int

    public init(fileName: String, totalSize: Int64, chunkSize: Int, chunkCount: Int) {
        self.fileName = fileName
        self.totalSize = totalSize
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
    }
}

public struct UploadSessionStatus: Codable, Sendable {
    public let sessionID: String
    public let fileName: String
    public let totalSize: Int64
    public let chunkCount: Int
    public let receivedChunks: [Int]
    public let approved: Bool
    public let completed: Bool
}
