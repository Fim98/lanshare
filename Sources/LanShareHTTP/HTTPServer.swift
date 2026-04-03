import Foundation
import NIO
import NIOHTTP1
import LanShareCore

public final class HTTPServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private var channel: Channel?

    private let shareStore: ShareStore
    private let uploadStore: UploadStore
    private weak var approvalProvider: UploadApprovalProviding?
    private let paths: AppPaths

    public init(shareStore: ShareStore, uploadStore: UploadStore, approvalProvider: UploadApprovalProviding?, paths: AppPaths) {
        self.shareStore = shareStore
        self.uploadStore = uploadStore
        self.approvalProvider = approvalProvider
        self.paths = paths
    }

    public func start(host: String = "0.0.0.0", port: Int = 9000) throws {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(
                        shareStore: self.shareStore,
                        uploadStore: self.uploadStore,
                        approvalProvider: self.approvalProvider,
                        paths: self.paths
                    ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        self.channel = try bootstrap.bind(host: host, port: port).wait()
    }

    public func stop() throws {
        try channel?.close().wait()
        try group.syncShutdownGracefully()
    }

    public var localAddress: SocketAddress? { channel?.localAddress }
}

private final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer = ByteBufferAllocator().buffer(capacity: 0)

    private let shareStore: ShareStore
    private let uploadStore: UploadStore
    private weak var approvalProvider: UploadApprovalProviding?
    private let paths: AppPaths

    init(shareStore: ShareStore, uploadStore: UploadStore, approvalProvider: UploadApprovalProviding?, paths: AppPaths) {
        self.shareStore = shareStore
        self.uploadStore = uploadStore
        self.approvalProvider = approvalProvider
        self.paths = paths
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer.clear()
        case .body(var buffer):
            bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let head = requestHead else { return }
            Task {
                let response = await self.route(head: head, body: self.bodyBuffer, remote: context.remoteAddress)
                self.writeResponse(context: context, response: response, version: head.version, keepAlive: head.isKeepAlive)
            }
        }
    }

    private func route(head: HTTPRequestHead, body: ByteBuffer, remote: SocketAddress?) async -> HTTPResponse {
        let path = head.uri.split(separator: "?").first.map(String.init) ?? head.uri

        if head.method == .GET, path == "/" {
            let html = WebAssets.indexHTML
            return .ok(.html(html))
        }

        if head.method == .GET, path == "/api/shares" {
            let items = shareStore.allItems()
            return .ok(.jsonEncodable(items))
        }

        if head.method == .GET, path.hasPrefix("/d/file/") {
            let id = String(path.dropFirst("/d/file/".count))
            guard let item = shareStore.item(id: id) else {
                return .notFound("未找到文件")
            }
            return serveFile(item: item, head: head)
        }

        if head.method == .GET, path.hasPrefix("/d/folder/") {
            let parts = path.split(separator: "/")
            if parts.count >= 4, parts[3] == "zip" {
                let id = String(parts[2])
                guard let item = shareStore.item(id: id) else { return .notFound("目录不存在") }
                return await serveFolderZip(item: item)
            }
        }

        if head.method == .POST, path == "/upload/init" {
            guard body.readableBytes > 0 else { return .badRequest("请求体为空") }
            let data = Data(body.readableBytesView)
            guard let payload = try? JSONDecoder().decode(UploadInitPayload.self, from: data) else {
                return .badRequest("上传初始化参数无效")
            }

            let ip = remote?.ipAddress ?? "未知设备"
            let approved = await approvalProvider?.requestApproval(clientIP: ip, payload: payload) ?? false
            if !approved {
                return .forbidden("已拒绝接收此上传")
            }

            let sessionTempDir = paths.uploadTempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: sessionTempDir, withIntermediateDirectories: true)
            let out = paths.uploadInboxDir.appendingPathComponent(payload.fileName)
            let s = await uploadStore.create(
                fileName: payload.fileName,
                totalSize: payload.totalSize,
                chunkSize: payload.chunkSize,
                chunkCount: payload.chunkCount,
                tempDir: sessionTempDir,
                outputPath: out
            )
            await uploadStore.setApproved(id: s.id, approved: true)
            return .ok(.json(["sessionID": s.id]))
        }

        if head.method == .PUT, path.hasPrefix("/upload/chunk/") {
            let sessionID = String(path.dropFirst("/upload/chunk/".count))
            guard let indexHeader = head.headers.first(name: "x-chunk-index"), let index = Int(indexHeader) else {
                return .badRequest("缺少分片索引")
            }

            guard let session = await uploadStore.get(id: sessionID), session.approved else {
                return .forbidden("上传会话不存在或未获准")
            }

            let chunkURL = session.tempDir.appendingPathComponent("\(index).part")
            let data = Data(body.readableBytesView)
            if !data.isEmpty {
                do {
                    try data.write(to: chunkURL, options: Data.WritingOptions.atomic)
                    await uploadStore.markReceived(id: sessionID, index: index)
                    return .ok(.json(["ok": true]))
                } catch {
                    return .internalError("写入分片失败")
                }
            }
            return .badRequest("分片数据为空")
        }

        if head.method == .GET, path.hasPrefix("/upload/status/") {
            let sessionID = String(path.dropFirst("/upload/status/".count))
            guard let status = await uploadStore.status(id: sessionID) else {
                return .notFound("上传会话不存在")
            }
            return .ok(.jsonEncodable(status))
        }

        if head.method == .POST, path.hasPrefix("/upload/complete/") {
            let sessionID = String(path.dropFirst("/upload/complete/".count))
            guard let session = await uploadStore.get(id: sessionID), session.approved else {
                return .forbidden("上传会话无效")
            }
            do {
                try mergeChunks(session: session)
                await uploadStore.markCompleted(id: sessionID)
                return .ok(.json(["ok": true, "path": session.outputPath.path]))
            } catch {
                return .internalError("合并分片失败")
            }
        }

        return .notFound("接口不存在")
    }

    private func mergeChunks(session: UploadStore.Session) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: session.outputPath.path) {
            try fm.removeItem(at: session.outputPath)
        }
        fm.createFile(atPath: session.outputPath.path, contents: nil)
        let handle = try FileHandle(forWritingTo: session.outputPath)
        defer { try? handle.close() }

        for idx in 0..<session.chunkCount {
            let chunkURL = session.tempDir.appendingPathComponent("\(idx).part")
            let data = try Data(contentsOf: chunkURL)
            try handle.write(contentsOf: data)
        }
    }

    private func serveFolderZip(item: ShareItem) async -> HTTPResponse {
        guard item.kind == .directory || item.kind == .symlink else {
            return .badRequest("仅目录支持打包下载")
        }

        let source = URL(fileURLWithPath: item.resolvedPath)
        let zipURL = paths.cacheDir.appendingPathComponent("\(item.id)-\(Int(Date().timeIntervalSince1970)).zip")
        do {
            try createZip(fromDirectory: source, outputZip: zipURL)
            guard let data = try? Data(contentsOf: zipURL) else {
                return .internalError("读取压缩包失败")
            }
            try? FileManager.default.removeItem(at: zipURL)
            return .ok(.binary(data, contentType: "application/zip", fileName: "\(item.displayName).zip"))
        } catch {
            return .internalError("打包目录失败")
        }
    }

    private func createZip(fromDirectory source: URL, outputZip: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputZip.path) {
            try fm.removeItem(at: outputZip)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source.deletingLastPathComponent()
        process.arguments = ["-r", "-q", outputZip.path, source.lastPathComponent]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "LanShare", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "zip 执行失败"])
        }
    }

    private func serveFile(item: ShareItem, head: HTTPRequestHead) -> HTTPResponse {
        let url = URL(fileURLWithPath: item.resolvedPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .notFound("文件已不存在")
        }
        defer { try? handle.close() }

        guard let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
            return .internalError("无法读取文件信息")
        }

        if let rangeHeader = head.headers.first(name: "range"),
           let (start, end) = parseRange(rangeHeader: rangeHeader, fileSize: fileSize),
           start <= end,
           start >= 0,
           end < fileSize {
            let length = end - start + 1
            do {
                try handle.seek(toOffset: UInt64(start))
                guard let data = try handle.read(upToCount: Int(length)) else {
                    return .internalError("读取分片失败")
                }
                return .partial(data: data, start: start, end: end, total: fileSize, fileName: item.displayName)
            } catch {
                return .internalError("读取文件失败")
            }
        }

        do {
            try handle.seek(toOffset: 0)
            guard let data = try handle.readToEnd() else {
                return .internalError("读取文件失败")
            }
            return .ok(.binary(data, contentType: "application/octet-stream", fileName: item.displayName, extraHeaders: [
                "Accept-Ranges": "bytes"
            ]))
        } catch {
            return .internalError("读取文件失败")
        }
    }

    private func parseRange(rangeHeader: String, fileSize: Int64) -> (Int64, Int64)? {
        guard rangeHeader.lowercased().hasPrefix("bytes=") else { return nil }
        let value = rangeHeader.dropFirst(6)
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let lhs = String(parts[0])
        let rhs = String(parts[1])

        if lhs.isEmpty, let suffix = Int64(rhs) {
            let start = max(0, fileSize - suffix)
            return (start, fileSize - 1)
        }

        guard let start = Int64(lhs) else { return nil }
        if rhs.isEmpty {
            return (start, fileSize - 1)
        }
        guard let end = Int64(rhs) else { return nil }
        return (start, end)
    }

    private func writeResponse(context: ChannelHandlerContext, response: HTTPResponse, version: HTTPVersion, keepAlive: Bool) {
        var headers = response.headers
        headers.add(name: "Server", value: "LanShare")
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        headers.add(name: "Content-Length", value: "\(response.body.readableBytes)")

        let head = HTTPResponseHead(version: version, status: response.status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(response.body))), promise: nil)
        let promise: EventLoopPromise<Void>? = keepAlive ? nil : context.eventLoop.makePromise()
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        promise?.futureResult.whenComplete { _ in context.close(promise: nil) }
    }
}

private struct HTTPResponse {
    let status: HTTPResponseStatus
    var headers: HTTPHeaders
    let body: ByteBuffer

    static func ok(_ bodyType: BodyType) -> HTTPResponse {
        make(status: .ok, bodyType: bodyType)
    }

    static func partial(data: Data, start: Int64, end: Int64, total: Int64, fileName: String) -> HTTPResponse {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/octet-stream")
        headers.add(name: "Accept-Ranges", value: "bytes")
        headers.add(name: "Content-Range", value: "bytes \(start)-\(end)/\(total)")
        headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(fileName)\"")
        var buf = ByteBufferAllocator().buffer(capacity: data.count)
        buf.writeBytes(data)
        return HTTPResponse(status: .partialContent, headers: headers, body: buf)
    }

    static func badRequest(_ message: String) -> HTTPResponse { .make(status: .badRequest, bodyType: .text(message)) }
    static func notFound(_ message: String) -> HTTPResponse { .make(status: .notFound, bodyType: .text(message)) }
    static func forbidden(_ message: String) -> HTTPResponse { .make(status: .forbidden, bodyType: .text(message)) }
    static func internalError(_ message: String) -> HTTPResponse { .make(status: .internalServerError, bodyType: .text(message)) }

    private static func make(status: HTTPResponseStatus, bodyType: BodyType) -> HTTPResponse {
        var headers = HTTPHeaders()
        var buffer = ByteBufferAllocator().buffer(capacity: 0)

        switch bodyType {
        case .text(let str):
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            buffer.writeString(str)
        case .html(let str):
            headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
            buffer.writeString(str)
        case .json(let dict):
            headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: []), let text = String(data: data, encoding: .utf8) {
                buffer.writeString(text)
            }
        case .jsonEncodable(let enc):
            headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
            if let data = try? JSONEncoder().encode(AnyEncodable(enc)), let text = String(data: data, encoding: .utf8) {
                buffer.writeString(text)
            }
        case .binary(let data, let contentType, let fileName, let extraHeaders):
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(fileName)\"")
            for (k, v) in extraHeaders { headers.add(name: k, value: v) }
            buffer.writeBytes(data)
        }

        return HTTPResponse(status: status, headers: headers, body: buffer)
    }
}

private enum BodyType {
    case text(String)
    case html(String)
    case json([String: Any])
    case jsonEncodable(any Encodable)
    case binary(Data, contentType: String, fileName: String, extraHeaders: [String: String] = [:])
}

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ wrapped: any Encodable) {
        _encode = { encoder in
            try wrapped.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

private enum WebAssets {
    static let indexHTML = """
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>LanShare 局域网文件分享</title>
  <style>
    :root {
      --primary: #2563EB;
      --secondary: #3B82F6;
      --cta: #F97316;
      --bg: #F1F5F9;
      --surface: #FFFFFF;
      --text: #1E293B;
      --muted: #64748B;
      --border: #E2E8F0;
      --danger: #DC2626;
      --ok: #15803D;
      --shadow-soft: 0 10px 26px rgba(15, 23, 42, .06);
      --shadow-card: 0 8px 20px rgba(37, 99, 235, .08);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      font-family: "Noto Sans SC", "PingFang SC", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
    }

    .wrap {
      width: min(960px, calc(100% - 32px));
      margin: 24px auto 40px;
    }

    .hero {
      background: linear-gradient(180deg, #FFFFFF 0%, #F8FBFF 100%);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 24px;
      margin-bottom: 16px;
      box-shadow: var(--shadow-soft);
    }

    .badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      font-size: 13px;
      color: var(--primary);
      background: #EFF6FF;
      border: 1px solid #BFDBFE;
      border-radius: 999px;
      padding: 4px 10px;
      margin-bottom: 12px;
    }

    h1 {
      margin: 0;
      font-size: clamp(24px, 4vw, 36px);
      line-height: 1.2;
      letter-spacing: 0.3px;
    }

    .desc {
      margin: 10px 0 0;
      color: var(--muted);
      max-width: 60ch;
    }

    .grid {
      display: grid;
      grid-template-columns: 1.2fr 1fr;
      gap: 16px;
    }

    .card {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 16px;
      padding: 18px;
      box-shadow: var(--shadow-soft);
    }

    .card h2 {
      margin: 0 0 8px;
      font-size: 18px;
    }

    .tips {
      margin: 0 0 14px;
      color: var(--muted);
      font-size: 14px;
    }

    .list {
      list-style: none;
      margin: 0;
      padding: 0;
      display: grid;
      gap: 10px;
    }

    .item {
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 12px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      background: #fff;
    }

    .item-name {
      min-width: 0;
      font-size: 14px;
      font-weight: 600;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .item-type {
      font-size: 12px;
      color: var(--muted);
      margin-top: 2px;
    }

    .btn {
      appearance: none;
      border: 0;
      background: var(--primary);
      color: white;
      border-radius: 10px;
      min-height: 44px;
      padding: 0 14px;
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      transition: background-color .18s ease, opacity .18s ease;
      text-decoration: none;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      white-space: nowrap;
    }

    .btn:hover { background: var(--secondary); }
    .btn:active { opacity: .88; }

    .btn:focus-visible,
    input[type="file"]:focus-visible {
      outline: 3px solid #93C5FD;
      outline-offset: 2px;
    }

    .btn-cta { background: var(--cta); width: 100%; }
    .btn-cta:hover { background: #EA580C; }

    .uploader {
      display: grid;
      gap: 10px;
    }

    .input-wrap {
      border: 1px dashed #94A3B8;
      border-radius: 12px;
      padding: 12px;
      background: #F8FAFC;
    }

    label {
      font-size: 14px;
      font-weight: 600;
      margin-bottom: 6px;
      display: block;
    }

    .file-input-hidden {
      position: absolute;
      width: 1px;
      height: 1px;
      opacity: 0;
      pointer-events: none;
    }

    .file-picker {
      min-height: 124px;
      border: 1px dashed #93C5FD;
      border-radius: 12px;
      background: #EFF6FF;
      display: grid;
      place-items: center;
      gap: 8px;
      padding: 14px;
      cursor: pointer;
      transition: background-color .18s ease, border-color .18s ease;
    }

    .file-picker:hover {
      background: #DBEAFE;
      border-color: #60A5FA;
    }

    .file-picker:focus-visible {
      outline: 3px solid #93C5FD;
      outline-offset: 2px;
    }

    .file-plus {
      width: 40px;
      height: 40px;
      border-radius: 10px;
      background: #2563EB;
      color: white;
      display: grid;
      place-items: center;
      font-size: 28px;
      line-height: 1;
      font-weight: 500;
    }

    .file-main {
      font-size: 14px;
      font-weight: 600;
      color: var(--text);
      text-align: center;
    }

    .file-sub {
      font-size: 12px;
      color: var(--muted);
      text-align: center;
    }

    .file-name {
      margin-top: 8px;
      min-height: 20px;
      font-size: 13px;
      color: var(--muted);
      text-align: center;
      word-break: break-all;
    }

    .status {
      margin: 0;
      font-size: 14px;
      color: var(--muted);
      min-height: 22px;
    }

    .status.error { color: var(--danger); }
    .status.ok { color: #15803D; }

    .progress {
      width: 100%;
      height: 8px;
      border-radius: 999px;
      overflow: hidden;
      background: #E2E8F0;
    }

    .progress > span {
      display: block;
      height: 100%;
      width: 0%;
      background: var(--primary);
      transition: width .2s ease;
    }

    .empty {
      border: 1px dashed var(--border);
      border-radius: 12px;
      padding: 16px;
      font-size: 14px;
      color: var(--muted);
      background: #fff;
    }

    .footer {
      margin-top: 16px;
      color: var(--muted);
      font-size: 13px;
      text-align: center;
    }

    @media (max-width: 860px) {
      .grid { grid-template-columns: 1fr; }
      .wrap { width: min(720px, calc(100% - 24px)); margin: 12px auto 24px; }
      .hero { padding: 18px; }
    }

    @media (prefers-reduced-motion: reduce) {
      * { transition: none !important; }
    }
  </style>
</head>
<body>
  <main class="wrap">
    <section class="hero" aria-labelledby="title">
      <span class="badge">局域网 · 免账号 · 点对点</span>
      <h1 id="title">LanShare 文件分享</h1>
      <p class="desc">在同一局域网下，直接通过 IP:端口 访问。支持文件下载、目录打包下载、分片上传与主机确认接收。</p>
    </section>

    <section class="grid" aria-label="主要功能区">
      <article class="card" aria-labelledby="shareTitle">
        <h2 id="shareTitle">可下载工作空间</h2>
        <p class="tips">来自 macOS 菜单栏拖拽或“添加文件/目录”。</p>
        <ul id="shareList" class="list" aria-live="polite">
          <li class="empty">正在加载共享列表…</li>
        </ul>
      </article>

      <article class="card" aria-labelledby="uploadTitle">
        <h2 id="uploadTitle">上传到此电脑</h2>
        <p class="tips">上传前会在主机弹窗确认；仅在主机同意后开始传输。</p>

        <div class="uploader">
          <div class="input-wrap">
            <label for="fileInput">选择文件</label>
            <input id="fileInput" class="file-input-hidden" type="file" aria-describedby="uploadStatus fileName" />
            <div id="filePicker" class="file-picker" role="button" tabindex="0" aria-controls="fileInput" aria-label="选择文件上传">
              <div class="file-plus">+</div>
              <div class="file-main">点击选择文件</div>
              <div class="file-sub">支持大文件分片上传（需主机确认）</div>
            </div>
            <div id="fileName" class="file-name" aria-live="polite">尚未选择文件</div>
          </div>

          <button class="btn btn-cta" type="button" onclick="upload()">开始上传</button>

          <div class="progress" aria-hidden="true">
            <span id="progressBar"></span>
          </div>

          <p id="uploadStatus" class="status" role="status" aria-live="polite"></p>
        </div>
      </article>
    </section>

    <p class="footer">提示：如果列表为空，请在 macOS 菜单栏图标上拖入文件或目录。</p>
  </main>

  <script>
    function setStatus(text, type) {
      const el = document.getElementById('uploadStatus');
      el.textContent = text;
      el.className = 'status' + (type ? ` ${type}` : '');
    }

    function setProgress(percent) {
      document.getElementById('progressBar').style.width = `${Math.max(0, Math.min(100, percent))}%`;
    }

    async function loadShares() {
      const ul = document.getElementById('shareList');
      try {
        const res = await fetch('/api/shares');
        const arr = await res.json();

        if (!Array.isArray(arr) || arr.length === 0) {
          ul.innerHTML = '<li class="empty">暂无共享项。请在主机菜单栏中添加文件或目录。</li>';
          return;
        }

        ul.innerHTML = arr.map(it => {
          const isDir = it.kind === 'directory' || it.kind === 'symlink';
          const typeLabel = isDir ? '目录' : '文件';
          const href = isDir ? `/d/folder/${it.id}/zip` : `/d/file/${it.id}`;
          const action = isDir ? '下载 ZIP' : '下载文件';
          return `
            <li class="item">
              <div>
                <div class="item-name" title="${it.displayName}">${it.displayName}</div>
                <div class="item-type">${typeLabel}</div>
              </div>
              <a class="btn" href="${href}">${action}</a>
            </li>
          `;
        }).join('');
      } catch (e) {
        ul.innerHTML = '<li class="empty">加载失败，请稍后刷新页面。</li>';
      }
    }

    function initFilePicker() {
      const input = document.getElementById('fileInput');
      const picker = document.getElementById('filePicker');
      const fileName = document.getElementById('fileName');

      const openPicker = () => input.click();

      picker.addEventListener('click', openPicker);
      picker.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          openPicker();
        }
      });

      input.addEventListener('change', () => {
        const file = input.files?.[0];
        fileName.textContent = file ? `已选择：${file.name}` : '尚未选择文件';
      });
    }

    async function upload() {
      const input = document.getElementById('fileInput');
      const file = input.files?.[0];
      if (!file) {
        setStatus('请先选择一个文件。', 'error');
        return;
      }

      const chunkSize = 8 * 1024 * 1024;
      const chunkCount = Math.ceil(file.size / chunkSize);

      setStatus('正在等待主机确认接收…');
      setProgress(0);

      const initResp = await fetch('/upload/init', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          fileName: file.name,
          totalSize: file.size,
          chunkSize,
          chunkCount
        })
      });

      if (!initResp.ok) {
        setStatus('主机拒绝接收，或初始化失败。', 'error');
        return;
      }

      const initData = await initResp.json();
      const sessionID = initData.sessionID;

      for (let i = 0; i < chunkCount; i++) {
        const start = i * chunkSize;
        const end = Math.min(file.size, start + chunkSize);
        const chunk = file.slice(start, end);

        setStatus(`上传中：分片 ${i + 1}/${chunkCount}`);
        const r = await fetch(`/upload/chunk/${sessionID}`, {
          method: 'PUT',
          headers: { 'x-chunk-index': String(i) },
          body: chunk
        });

        if (!r.ok) {
          setStatus(`上传失败：分片 ${i + 1} 发送失败。`, 'error');
          return;
        }

        setProgress(((i + 1) / chunkCount) * 100);
      }

      const done = await fetch(`/upload/complete/${sessionID}`, { method: 'POST' });
      if (done.ok) {
        setStatus('上传完成，文件已保存到主机接收目录。', 'ok');
      } else {
        setStatus('上传收尾失败，请稍后重试。', 'error');
      }
    }

    initFilePicker();
    loadShares();
  </script>
</body>
</html>
"""
}
