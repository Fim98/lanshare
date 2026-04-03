# LanShare

macOS 菜单栏局域网文件共享工具。无需账号、无需服务器，同一网络下的设备通过浏览器即可互传文件。

## 功能

- **文件共享** — 将文件或目录添加到共享列表，局域网内其他设备通过浏览器下载
- **目录打包** — 目录自动打包为 ZIP 下载
- **分片上传** — 大文件分片上传，支持断点续传查询
- **主机确认** — 上传前在 macOS 端弹窗确认，拒绝可疑文件
- **拖拽添加** — 直接拖拽文件到状态栏图标即可共享
- **零配置** — 启动即用，自动检测局域网 IP，默认端口 `9000`

## 快速开始

### 环境要求

- macOS 14.0 (Sonoma) 及以上
- Xcode Command Line Tools (`xcode-select --install`)
- Swift 5.10+

### 构建 & 运行

```bash
# 构建
make build

# 构建并运行
make run

# 安装到 /Applications
make install

# 清理构建产物
make clean
```

构建产物为 `dist/LanShare.app`，双击即可启动。

### 自定义签名

```bash
make build SIGN_ID="Developer ID Application: Your Name (TEAMID)"
```

默认使用 ad-hoc 签名 (`-`)。

## 架构

```
Sources/
├── LanShareApp/          # 应用入口层
│   ├── main.swift        # NSApplication 启动，.accessory 模式（菜单栏应用）
│   └── AppController.swift
│       ├── AppController          — 状态栏菜单、拖拽、文件管理
│       ├── ApprovalProvider       — 上传确认弹窗
│       ├── StatusDropTargetView   — 状态栏拖放区域
│       └── LocalNetwork           — 局域网 IP 检测
│
├── LanShareCore/         # 核心业务层（无 UI 依赖）
│   ├── Models.swift      # ShareItem / UploadInitPayload / UploadSessionStatus
│   ├── ShareStore.swift  # 共享项 CRUD，JSON 持久化
│   ├── UploadStore.swift # 上传会话管理（Swift Actor）
│   ├── Approval.swift    # UploadApprovalProviding 协议
│   └── AppPaths.swift    # 目录布局（~/Library/Application Support/LanShare 等）
│
└── LanShareHTTP/         # HTTP 服务层
    └── HTTPServer.swift
        ├── HTTPServer    — SwiftNIO 引导、启动、停止
        ├── HTTPHandler   — 请求路由与响应
        └── WebAssets     — 内嵌前端 HTML/CSS/JS
```

### 数据流

```
其他设备浏览器 ──HTTP──▶ HTTPServer (SwiftNIO)
                              │
                    ┌─────────┼──────────┐
                    ▼         ▼          ▼
              ShareStore  UploadStore  ApprovalProvider
                    │         │              │
              文件系统读写  分片管理      macOS 弹窗确认
```

### API 路由

| 方法   | 路径                     | 说明                 |
| ------ | ------------------------ | -------------------- |
| GET    | `/`                      | Web UI 页面          |
| GET    | `/api/shares`            | 获取共享列表         |
| GET    | `/d/file/:id`            | 下载文件（支持 Range）|
| GET    | `/d/folder/:id/zip`      | 打包目录为 ZIP 下载  |
| POST   | `/upload/init`           | 初始化上传会话       |
| PUT    | `/upload/chunk/:session` | 上传分片             |
| GET    | `/upload/status/:session`| 查询上传状态         |
| POST   | `/upload/complete/:session` | 完成上传并合并分片 |

### 文件存储位置

| 用途     | 路径                                          |
| -------- | --------------------------------------------- |
| 共享状态 | `~/Library/Application Support/LanShare/State/` |
| 上传临时 | `~/Library/Caches/LanShare/Uploads/`            |
| 接收目录 | `~/Downloads/LanShare Inbox/`                   |

## 二次开发

### 添加新的 API 端点

在 `Sources/LanShareHTTP/HTTPServer.swift` 的 `route(head:body:remote:)` 方法中添加路由分支：

```swift
if head.method == .GET, path == "/api/example" {
    return .ok(.json(["message": "hello"]))
}
```

### 修改 Web UI

前端 HTML/CSS/JS 内嵌在 `Sources/LanShareHTTP/HTTPServer.swift` 的 `WebAssets.indexHTML` 中。可直接修改样式或结构，无需额外构建工具。

### 替换应用图标

1. 准备 `.icns` 格式图标文件
2. 放入 `packaging/AppIcon.icns`
3. 运行 `make build`，Makefile 会自动将其打包到 app bundle

### 修改上传确认行为

实现 `UploadApprovalProviding` 协议（`Sources/LanShareCore/Approval.swift`），替换 `ApprovalProvider` 即可自定义确认逻辑（如自动接收、白名单等）。

### 修改默认端口

在 `Sources/LanShareApp/AppController.swift` 的 `startServer()` 中修改 `port` 参数。

## 发布流程

项目使用 GitHub Actions 自动打包发布：

1. 更新 `packaging/Info.plist` 中的版本号
2. 创建并推送 tag：
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. GitHub Actions 自动构建 → 打包 ZIP → 创建 Release 并上传资产

Release 产物命名格式：`LanShare-v{version}.zip`

## 技术栈

- **语言**：Swift 5.10
- **网络**：SwiftNIO (HTTP/1.1)
- **平台**：macOS 14+ (AppKit, 菜单栏应用)
- **构建**：Swift Package Manager + Makefile
- **CI/CD**：GitHub Actions

## License

MIT
