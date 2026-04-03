import Foundation

public final class ShareStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LanShare.ShareStore")
    private var items: [String: ShareItem] = [:]
    private let stateFile: URL

    public init(baseDirectory: URL) {
        self.stateFile = baseDirectory.appendingPathComponent("shares.json")
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        self.load()
    }

    public func allItems() -> [ShareItem] {
        queue.sync {
            items.values.sorted(by: { $0.createdAt > $1.createdAt })
        }
    }

    public func item(id: String) -> ShareItem? {
        queue.sync { items[id] }
    }

    @discardableResult
    public func addPath(_ path: URL) throws -> ShareItem {
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL
        let original = path.standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
            throw NSError(domain: "LanShare", code: 404, userInfo: [NSLocalizedDescriptionKey: "文件不存在"])
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: resolved.path)
        let modifiedAt = (attrs[.modificationDate] as? Date) ?? Date()
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let kind: ShareKind
        if (try? original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            kind = .symlink
        } else {
            kind = isDir.boolValue ? .directory : .file
        }

        let item = ShareItem(
            id: UUID().uuidString,
            displayName: original.lastPathComponent,
            originalPath: original.path,
            resolvedPath: resolved.path,
            kind: kind,
            size: size,
            modifiedAt: modifiedAt,
            createdAt: Date()
        )

        queue.sync {
            items[item.id] = item
            persistLocked()
        }
        return item
    }

    public func remove(id: String) {
        queue.sync {
            items.removeValue(forKey: id)
            persistLocked()
        }
    }

    private func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: stateFile) else { return }
            guard let arr = try? JSONDecoder().decode([ShareItem].self, from: data) else { return }
            self.items = Dictionary(uniqueKeysWithValues: arr.map { ($0.id, $0) })
        }
    }

    private func persistLocked() {
        let arr = Array(items.values)
        guard let data = try? JSONEncoder().encode(arr) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }
}
