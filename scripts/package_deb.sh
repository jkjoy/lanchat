#!/usr/bin/env bash
# 将 Flutter Linux release bundle 打包为 .deb
# 用法: package_deb.sh <版本> [bundle路径] [架构]
set -euo pipefail

VERSION="${1:?用法: package_deb.sh <版本> [bundle路径] [架构]}"
BUNDLE="${2:-build/linux/x64/release/bundle}"
ARCH="${3:-amd64}"
APP_NAME="lanchat"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$BUNDLE" ] || [ ! -x "$BUNDLE/$APP_NAME" ]; then
  echo "错误: bundle 不存在或缺少可执行文件 $BUNDLE/$APP_NAME" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 目录结构
mkdir -p "$STAGE/opt/$APP_NAME"
mkdir -p "$STAGE/usr/bin"
mkdir -p "$STAGE/usr/share/applications"
mkdir -p "$STAGE/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$STAGE/usr/share/doc/$APP_NAME"
mkdir -p "$STAGE/DEBIAN"

# 拷贝 Flutter bundle(lanchat 可执行文件 + lib/ + data)
cp -r "$BUNDLE/." "$STAGE/opt/$APP_NAME/"
chmod +x "$STAGE/opt/$APP_NAME/$APP_NAME"

# 启动包装脚本(设置数据目录可选)
cat > "$STAGE/usr/bin/$APP_NAME" <<EOF
#!/bin/sh
exec /opt/$APP_NAME/$APP_NAME "\$@"
EOF
chmod +x "$STAGE/usr/bin/$APP_NAME"

# .desktop 入口
cat > "$STAGE/usr/share/applications/$APP_NAME.desktop" <<EOF
[Desktop Entry]
Name=LanChat
Name[zh_CN]=LanChat
Comment=局域网即时通讯 - 无需服务器的 P2P 聊天
Comment[zh_CN]=局域网即时通讯 - 无需服务器的 P2P 聊天
Exec=$APP_NAME
Icon=$APP_NAME
Terminal=false
Type=Application
Categories=Network;Chat;InstantMessaging;
Keywords=lan;chat;局域网;聊天;
EOF

# 图标(用 Flutter 默认 fallback;若日后提供独立图标可替换)
cat > "$STAGE/usr/share/icons/hicolor/scalable/apps/$APP_NAME.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">
  <rect width="128" height="128" rx="24" fill="#2F6FED"/>
  <circle cx="42" cy="58" r="9" fill="#fff"/>
  <circle cx="64" cy="58" r="9" fill="#fff"/>
  <circle cx="86" cy="58" r="9" fill="#fff"/>
  <path d="M42 80c0-12 10-20 22-20s22 8 22 20" stroke="#fff" stroke-width="6" fill="none" stroke-linecap="round"/>
</svg>
EOF

# control
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $APP_NAME
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: jkjoy <jkjoy@users.noreply.github.com>
Depends: libgtk-3-0 (>= 3.20), libc6 (>= 2.31)
Description: LanChat - 局域网即时通讯
 全对等 Mesh 组网,无需服务器;跨平台;支持文件传输、
 群聊、加密。Linux 桌面客户端。
Homepage: https://github.com/jkjoy/lanchat
EOF

# changelog 占位(doc)
cat > "$STAGE/usr/share/doc/$APP_NAME/changelog.Debian.gz" <<EOF
LanChat $VERSION: Linux 桌面版发布。
EOF
gzip -f "$STAGE/usr/share/doc/$APP_NAME/changelog.Debian.gz"

# 打包
OUT="$ROOT/build/lanchat_${VERSION}_${ARCH}.deb"
mkdir -p "$ROOT/build"
dpkg-deb --build --root-owner-group "$STAGE" "$OUT" >/dev/null
echo "✓ 已生成 $OUT"