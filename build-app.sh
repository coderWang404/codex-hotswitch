#!/bin/bash
# 构建 "Codex 热切换.app"（原生菜单栏 App，内置 Node 版工具）
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Codex 热切换"
EXEC_NAME="CodexHotSwitch"
DIST="$SRC_DIR/dist"
APP="$DIST/$APP_NAME.app"

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift"
swiftc -O -swift-version 5 \
  -o "$APP/Contents/MacOS/$EXEC_NAME" \
  "$SRC_DIR/app/"*.swift \
  -framework AppKit -framework CryptoKit

echo "==> 内置 Node 工具"
mkdir -p "$APP/Contents/Resources/codex-hotswitch"
rsync -a \
  --exclude 'node_modules' --exclude 'dist' --exclude '.DS_Store' \
  "$SRC_DIR/bin" "$SRC_DIR/src" "$SRC_DIR/package.json" "$SRC_DIR/README.md" \
  "$APP/Contents/Resources/codex-hotswitch/"

echo "==> Info.plist"
cp "$SRC_DIR/app/Info.plist" "$APP/Contents/Info.plist"

echo "==> 生成图标"
ICON_TMP="$(mktemp -d)"
if swiftc -O -swift-version 5 -o "$ICON_TMP/makeicon" "$SRC_DIR/tools/make-icon.swift" -framework AppKit 2>/dev/null; then
  if "$ICON_TMP/makeicon" "$ICON_TMP/icon_1024.png" 2>/dev/null; then
    ICONSET="$ICON_TMP/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512; do
      sips -z $size $size "$ICON_TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
      double=$((size * 2))
      if [ "$double" -le 1024 ]; then
        sips -z $double $double "$ICON_TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
      fi
    done
    if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
      echo "    图标已生成"
    fi
  fi
fi
rm -rf "$ICON_TMP"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "    (签名跳过，不影响本机运行)"

echo ""
echo "✅ 构建完成: $APP"
echo "   运行: open \"$APP\""
echo "   安装: cp -R \"$APP\" /Applications/"
