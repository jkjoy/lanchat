# LanChat 更新日志

## v1.2.1 (2026-09-26)

### 修复

- Windows Release 改为发布完整安装程序和便携 ZIP,不再发布缺少 Flutter 及插件 DLL 的单独 EXE

## v1.1.0 (2026-09-25)

新增 Linux 桌面版,提供 Debian/Ubuntu 的 .deb 安装包。

### 变更
- 新增 Linux 平台支持(Flutter Linux 桌面)
- GitHub Actions 新增 `Build Linux (.deb)` job:构建 release bundle 并打包为 `lanchat_<ver>_amd64.deb`
- Release 自动附带 `.deb` 安装包

## v1.0.0 (2026-09-25)

首个发布版本:局域网即时通讯应用,三端(Windows/Android/macOS)全对等 Mesh 组网。

### 功能
- 设备自动发现(UDP 广播 + 组播)与 WebSocket 全连接,无需服务器
- 私聊 + 送达回执、SQLite 历史、离线消息补发
- 文件传输(HTTP 分块 + Range 断点续传)、图片粘贴/拖拽发送
- 口令配对 AES-256-GCM 端到端加密
- 语音消息(m4a,经文件通道发送)
- 群发消息、群组会话(建群/邀请/群内聊天)、群消息已读回执
- 消息搜索(跨会话全文检索)、未读计数 + 系统通知
- Android:文件保存到公共 Downloads + 后台保活前台服务

### 构建
- Android APK、Windows exe、macOS app,均可由 GitHub Actions 自动构建
