import Foundation

public actor UploadStore {
    public struct Session: Sendable {
        public let id: String
        public let fileName: String
        public let totalSize: Int64
        public let chunkSize: Int
        public let chunkCount: Int
        public var received: Set<Int>
        public var approved: Bool
        public var completed: Bool
        public let tempDir: URL
        public let outputPath: URL
    }

    private var sessions: [String: Session] = [:]

    public init() {}

    public func create(fileName: String, totalSize: Int64, chunkSize: Int, chunkCount: Int, tempDir: URL, outputPath: URL) -> Session {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let s = Session(
            id: id,
            fileName: fileName,
            totalSize: totalSize,
            chunkSize: chunkSize,
            chunkCount: chunkCount,
            received: [],
            approved: false,
            completed: false,
            tempDir: tempDir,
            outputPath: outputPath
        )
        sessions[id] = s
        return s
    }

    public func get(id: String) -> Session? { sessions[id] }

    public func setApproved(id: String, approved: Bool) {
        guard var s = sessions[id] else { return }
        s.approved = approved
        sessions[id] = s
    }

    public func markReceived(id: String, index: Int) {
        guard var s = sessions[id] else { return }
        s.received.insert(index)
        sessions[id] = s
    }

    public func markCompleted(id: String) {
        guard var s = sessions[id] else { return }
        s.completed = true
        sessions[id] = s
    }

    public func remove(id: String) {
        sessions.removeValue(forKey: id)
    }

    public func status(id: String) -> UploadSessionStatus? {
        guard let s = sessions[id] else { return nil }
        return UploadSessionStatus(
            sessionID: s.id,
            fileName: s.fileName,
            totalSize: s.totalSize,
            chunkCount: s.chunkCount,
            receivedChunks: s.received.sorted(),
            approved: s.approved,
            completed: s.completed
        )
    }
}
