import Foundation

public struct AppPaths {
    public let appSupport: URL
    public let sharesStateDir: URL
    public let cacheDir: URL
    public let uploadTempDir: URL
    public let uploadInboxDir: URL

    public init(fileManager: FileManager = .default) {
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupport = appSupportBase.appendingPathComponent("LanShare", isDirectory: true)
        sharesStateDir = appSupport.appendingPathComponent("State", isDirectory: true)

        let cacheBase = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = cacheBase.appendingPathComponent("LanShare", isDirectory: true)
        uploadTempDir = cacheDir.appendingPathComponent("Uploads", isDirectory: true)

        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        uploadInboxDir = downloads.appendingPathComponent("LanShare Inbox", isDirectory: true)
    }

    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: sharesStateDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: uploadTempDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: uploadInboxDir, withIntermediateDirectories: true)
    }
}
