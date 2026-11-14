#!/usr/bin/env bash
set -euo pipefail

# GitHub Actions 环境变量，GITHUB_WORKSPACE 是源码根目录
WORKSPACE="${GITHUB_WORKSPACE}"
cd "${WORKSPACE}"

# 包基础信息
PKG_NAME="tsukimi"
PKG_ARCH="amd64"
MAINTAINER="Tsukimi Build <build@tsukimi.example>"
DESCRIPTION="Tsukimi - Simple MPD client written in Rust with GTK4"
BINARY_TARGET="x86_64-unknown-linux-gnu"

# 自动获取版本：优先使用 tag，否则 commit hash
if [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
    PKG_VERSION="${GITHUB_REF#refs/tags/}"
else
    PKG_VERSION="0.0.0-${GITHUB_SHA::8}"
fi

BUILD_DIR="${WORKSPACE}/target/${BINARY_TARGET}/release"
DEB_ROOT="${WORKSPACE}/deb_root"
DEB_OUT_DIR="${WORKSPACE}/deb_output"

echo "====================================="
echo "PKG_NAME:      ${PKG_NAME}"
echo "PKG_VERSION:   ${PKG_VERSION}"
echo "PKG_ARCH:      ${PKG_ARCH}"
echo "WORKSPACE:     ${WORKSPACE}"
echo "====================================="

# 清理旧打包目录
rm -rf "${DEB_ROOT}" "${DEB_OUT_DIR}"
mkdir -p "${DEB_ROOT}/usr/bin"
mkdir -p "${DEB_ROOT}/usr/share/applications"
mkdir -p "${DEB_ROOT}/usr/share/icons/hicolor/scalable/apps"
mkdir -p "${DEB_ROOT}/DEBIAN"
mkdir -p "${DEB_OUT_DIR}"

# Cargo 编译 release
cargo build --release --target "${BINARY_TARGET}"

# 复制主程序
cp "${BUILD_DIR}/${PKG_NAME}" "${DEB_ROOT}/usr/bin/"

# desktop 文件
if [ -f "${WORKSPACE}/data/${PKG_NAME}.desktop" ]; then
    cp "${WORKSPACE}/data/${PKG_NAME}.desktop" "${DEB_ROOT}/usr/share/applications/"
fi

# svg图标
if [ -f "${WORKSPACE}/data/${PKG_NAME}.svg" ]; then
    cp "${WORKSPACE}/data/${PKG_NAME}.svg" "${DEB_ROOT}/usr/share/icons/hicolor/scalable/apps/"
fi

# DEBIAN control
cat > "${DEB_ROOT}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Architecture: ${PKG_ARCH}
Maintainer: ${MAINTAINER}
Section: utils
Priority: optional
Depends: libgtk-4-1, libadwaita-1-0, libmpdclient2
Description: ${DESCRIPTION}
EOF

# 构建 deb
dpkg-deb --build --root-owner-group "${DEB_ROOT}" "${DEB_OUT_DIR}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"

echo "✅ DEB build done!"
ls -la "${DEB_OUT_DIR}/"
