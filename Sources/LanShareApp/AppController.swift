import Foundation
import AppKit
import LanShareCore
import LanShareHTTP

final class ApprovalProvider: UploadApprovalProviding {
    func requestApproval(clientIP: String, payload: UploadInitPayload) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let app = NSApplication.shared
                app.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.icon = AlertIconProvider.bestAvailableIcon()
                alert.messageText = "接收文件确认"
                alert.informativeText = "设备 \(clientIP) 请求上传文件：\n\(payload.fileName)\n大小：\(ByteCountFormatter.string(fromByteCount: payload.totalSize, countStyle: .file))\n\n是否接收？"
                alert.addButton(withTitle: "接收")
                alert.addButton(withTitle: "拒绝")

                let result = alert.runModal()
                continuation.resume(returning: result == .alertFirstButtonReturn)
            }
        }
    }
}

private enum AlertIconProvider {
    static func bestAvailableIcon() -> NSImage? {
        if let appIcon = NSApp.applicationIconImage, appIcon.size.width > 1 {
            return appIcon
        }

        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url), image.size.width > 0 {
            return image
        }

        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .medium, scale: .large)
        return NSImage(systemSymbolName: "arrow.up.arrow.down.circle.fill", accessibilityDescription: "LanShare 提示")?
            .withSymbolConfiguration(config)
    }
}

final class AppController: NSObject {
    private let paths = AppPaths()
    private var shareStore: ShareStore!
    private let uploadStore = UploadStore()
    private let approvalProvider = ApprovalProvider()
    private var server: HTTPServer?

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusLabelItem: NSMenuItem!
    private var ipLabelItem: NSMenuItem!

    override init() {
        super.init()
        do {
            try paths.prepare()
        } catch {
            NSLog("路径初始化失败: \(error.localizedDescription)")
        }
        shareStore = ShareStore(baseDirectory: paths.sharesStateDir)
    }

    func start() {
        setupStatusItem()
        startServer()
        refreshMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let statusIcon = NSImage(systemSymbolName: "arrow.up.arrow.down.circle.fill", accessibilityDescription: "LanShare")
            statusIcon?.isTemplate = true
            button.image = statusIcon
            button.imagePosition = .imageOnly
            button.toolTip = "LanShare 局域网文件分享（支持拖拽文件到图标）"
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.action = #selector(showMenu(_:))

            let dropView = StatusDropTargetView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onDropFiles = { [weak self] urls in
                urls.forEach { self?.addToShare($0) }
            }
            button.addSubview(dropView)
        }

        statusMenu = NSMenu()
        statusLabelItem = NSMenuItem(title: "服务状态：启动中", action: nil, keyEquivalent: "")
        ipLabelItem = NSMenuItem(title: "访问地址：获取中", action: nil, keyEquivalent: "")

        statusMenu.addItem(statusLabelItem)
        statusMenu.addItem(ipLabelItem)
        statusMenu.addItem(NSMenuItem.separator())

        let addFile = NSMenuItem(title: "添加文件…", action: #selector(addFile), keyEquivalent: "")
        addFile.target = self
        statusMenu.addItem(addFile)

        let addFolder = NSMenuItem(title: "添加目录…", action: #selector(addFolder), keyEquivalent: "")
        addFolder.target = self
        statusMenu.addItem(addFolder)

        let openInbox = NSMenuItem(title: "打开接收目录", action: #selector(openInboxDirectory), keyEquivalent: "")
        openInbox.target = self
        statusMenu.addItem(openInbox)

        let openWeb = NSMenuItem(title: "在浏览器打开本机页面", action: #selector(openLocalPage), keyEquivalent: "")
        openWeb.target = self
        statusMenu.addItem(openWeb)

        statusMenu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusMenu.addItem(quit)

        statusItem.menu = statusMenu
    }

    @objc private func showMenu(_ sender: Any?) {
        statusItem.button?.performClick(nil)
    }

    private func startServer() {
        do {
            let s = HTTPServer(
                shareStore: shareStore,
                uploadStore: uploadStore,
                approvalProvider: approvalProvider,
                paths: paths
            )
            try s.start(host: "0.0.0.0", port: 9000)
            server = s
            statusLabelItem.title = "服务状态：运行中"
            updateAddressText()
        } catch {
            statusLabelItem.title = "服务状态：启动失败"
            ipLabelItem.title = "错误：\(error.localizedDescription)"
        }
    }

    private func updateAddressText() {
        let port = (server?.localAddress?.port).map(String.init) ?? "9000"
        let ip = LocalNetwork.firstUsableIPv4() ?? "127.0.0.1"
        ipLabelItem.title = "访问地址：http://\(ip):\(port)"
    }

    private func refreshMenu() {
        let shares = shareStore.allItems()

        while statusMenu.items.count > 9 {
            statusMenu.removeItem(at: 9)
        }

        if shares.isEmpty {
            let empty = NSMenuItem(title: "当前无共享文件（可通过“添加文件/目录”添加）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            statusMenu.insertItem(empty, at: 9)
            return
        }

        let header = NSMenuItem(title: "共享项（点击移除）", action: nil, keyEquivalent: "")
        header.isEnabled = false
        statusMenu.insertItem(header, at: 9)

        for (offset, item) in shares.enumerated() {
            let menuItem = NSMenuItem(title: "• \(item.displayName)", action: #selector(removeShareItem(_:)), keyEquivalent: "")
            menuItem.representedObject = item.id
            menuItem.target = self
            statusMenu.insertItem(menuItem, at: 10 + offset)
        }
    }

    @objc private func addFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.title = "选择要共享的文件"

        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addToShare)
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.title = "选择要共享的目录"

        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addToShare)
    }

    private func addToShare(_ url: URL) {
        do {
            _ = try shareStore.addPath(url)
            refreshMenu()
        } catch {
            showError("添加失败", detail: error.localizedDescription)
        }
    }

    @objc private func removeShareItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        shareStore.remove(id: id)
        refreshMenu()
    }

    @objc private func openInboxDirectory() {
        NSWorkspace.shared.open(paths.uploadInboxDir)
    }

    @objc private func openLocalPage() {
        let port = (server?.localAddress?.port).map(String.init) ?? "9000"
        let url = URL(string: "http://127.0.0.1:\(port)")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quitApp() {
        if let server {
            try? server.stop()
        }
        NSApp.terminate(nil)
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.icon = AlertIconProvider.bestAvailableIcon()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

final class StatusDropTargetView: NSView {
    var onDropFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let canDrop = readURLs(from: sender).isEmpty == false
        return canDrop ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = readURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    private func readURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil)?
            .compactMap { $0 as? URL } ?? []
    }
}

final class LocalNetwork {
    static func firstUsableIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isRunning = (flags & IFF_RUNNING) == IFF_RUNNING
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, isRunning, !isLoopback else { continue }

            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                ptr.pointee.ifa_addr,
                socklen_t(addr.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let ip = String(cString: hostname)
                if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.") {
                    return ip
                }
            }
        }
        return nil
    }
}
