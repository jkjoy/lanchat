# LanChat

局域网即时通讯:无需互联网、无需服务器,Windows / Android / macOS 三端在同一 Wi-Fi/局域网内自动发现并互发消息。

## 功能

- **全对等组网(Mesh)**:每台设备既是 WebSocket 服务端也是客户端,任何一台关机不影响其他设备
- **自动发现**:启动后 UDP 广播 + 组播(`224.0.0.251`)定期宣告自己的存在,设备自动出现在列表中,无需输入 IP
- **实时在线状态**:对端 15 秒无消息即显示离线
- **离线兜底**:路由器开启 AP 隔离/广播被阻断时,可"手动添加设备"输入 IP 连接
- **消息历史**:SQLite 本地持久化,重新打开应用聊天记录仍在
- **送达回执**:发出消息收到对端回执后,勾号变为双勾
- **文件传输**:HTTP 分块传输,带进度条、断点续传(.part 续传),接收文件自动保存到应用文档目录
- **图片粘贴/拖拽发送**:桌面端拖入文件即发送,粘贴剪贴板图片可直接发
- **离线补发**:对端离线时消息标记 pending,重连后自动补发
- **配对加密**:同一口令(≥6 位)在两台设备开启后,聊天内容 AES-256-GCM 端到端加密
- **群发消息**:一键发送给所有在线设备(群发会话视图聚合收发记录)
- **语音消息**:桌面端与移动端录制 m4a 音频,经文件传输通道发送
- **群组会话**:创建群→邀请在线设备→群内消息互通(退出/成员管理)
- **群消息已读回执**:发出群消息后在气泡显示送达统计(如 2/3 已送达)
- **文件存公共目录**:Android 下载的文件自动保存到系统 Downloads/LanChat,桌面端保存到 ~/Downloads
- **消息搜索**:跨私聊/群聊全文检索本地历史(LIKE),点击结果直接跳转对应会话
- **Android 后台保活**:一键开启常驻通知前台服务,后台持续收消息
- **未读计数**:收到新消息会话列表与 AppBar 显示未读数,选中自动清零
- **系统通知**:收到新消息弹出系统级通知(Android/iOS/macOS)

## 快速开始

### 环境要求

| 平台 | 要求 |
|------|------|
| 运行 | Flutter SDK 3.x(Dart ≥ 3.10) |
| Windows 构建 | Visual Studio 2022(含"使用 C++ 的桌面开发") |
| Android 构建 | Android Studio / Android SDK + JDK 17 |
| macOS 构建 | Xcode + CocoaPods |

## 运行

```bash
flutter pub get

# macOS(本机)
flutter run -d macos

# Windows(需 Windows 机器或 CI)
flutter build windows        # 产物在 build/windows/x64/runner/Release/
flutter run -d windows

# Android
flutter build apk            # 产物在 build/app/outputs/flutter-apk/
flutter run -d <device>
```

两台设备都打开应用(同一局域网),即可在设备列表看到对方并开始聊天。

### Windows 安装

从 GitHub Release 下载 `lanchat-windows-x64-setup.exe` 并运行即可。也可以下载便携版 `lanchat-windows-x64.zip`,完整解压后再运行其中的 `lanchat.exe`。

Windows 客户端依赖同目录内的 Flutter 和插件 DLL,不能只复制或单独运行压缩包中的 `lanchat.exe`。

## 架构

```
lib/
├── main.dart                 # 入口:加载身份 → 启动服务 → 渲染
├── core/
│   ├── models.dart           # 设备模型、应用层消息信封、本机身份
│   ├── discovery.dart        # UDP 广播/组播设备发现(收到即回连)
│   ├── connection.dart       # WebSocket 服务端+客户端、握手、ping 保活、收敛去重
│   ├── database.dart         # SQLite:设备表 + 消息表(history)
│   ├── file_transfer.dart    # HTTP 分块传输 + Range 断点续传 + 信令
│   ├── pair_crypto.dart      # 配对口令 → AES-256-GCM 派生密钥加密
│   └── chat_service.dart     # 编排:发现→连接→收发→回执→持久化→加密→补发
└── ui/
    ├── home_screen.dart      # 桌面双栏 / 移动主从导航(自适应)
    ├── peer_list.dart        # 设备列表(头像/在线点/平台)、手动添加
    └── chat_pane.dart        # 消息气泡、送达状态、输入栏
```

### 通讯协议

- **发现**:UDP 周期广播 JSON `{"t":"lanchat:announce","id","name","platform","port"}`(组播 `224.0.0.251:53920` 互补),同时监听同端口
- **消息通道**:WebSocket(`ws://<host>:<port>/ws`,默认 53921,占用则自动换端口并随广播传播)。连接后互发 `hello` 握手交换身份;之后 `chat`/`receipt` 走统一信封:

```json
{ "type": "chat", "from": "dev-xxx", "to": "dev-yyy",
  "id": "msg-uuid", "ts": 1726800000000, "payload": { "text": "hi" } }
```

- **心跳**:WebSocket 原生 ping(15s),16s 无 pong 判定断线;空闲 20s 关闭残留连接,由发现层驱动重连
- **控制面**:UDP 53920 / WS 53921,可配置防火墙精确放行

## 平台注意事项

- **Android**:已在 Manifest 声明 `INTERNET`、`CHANGE_WIFI_MULTICAST_STATE`、`WAKE_LOCK` 等权限并启用明文流量(`usesCleartextTraffic`),局域网 HTTP/WS 可直连
- **macOS**:已配置 Sandbox 的 `network.server` / `network.client` entitlements
- **Windows**:首次运行请在防火墙弹窗中允许"专用网络"入站,否则收不到消息
- **文件端口**:文件传输 HTTP 端口默认 53922(占用则自动换并随广播传播)

## 已知边界(诚实地说明)

- 配对加密为对称口令:两台设备使用相同口令;若口令泄露,第三方可解密全部历史与未来消息
- Android 后台化后系统可能暂停应用,收消息依赖前台运行
- 支持 ≤20 台设备规模的家庭/办公室网络;设备过多时全连接数(N×(N−1)/2)增长较快

## Roadmap

- [x] 文件传输(分块 + 进度 + 断点续传)
- [x] 图片粘贴/拖拽发送
- [x] 离线消息补发
- [x] 口令配对加密(AES-256-GCM)
- [x] 群发消息(广播给所有在线设备)
- [x] 语音消息(m4a 文件通道发送)
- [x] 群组会话(建群/邀请/群内聊天)
- [x] Android 文件保存到系统 Downloads(Android 10+ MediaStore,以下直接写入)
- [x] 消息搜索/全文检索(LIKE 跨会话)
- [x] 未读计数 + 系统通知
- [ ] Windows/Android 真机冒烟测试
- [ ] 离线消息推送(Android 前台服务)
