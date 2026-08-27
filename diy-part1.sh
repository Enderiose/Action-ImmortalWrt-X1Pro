#!/bin/bash
# Apply the X1 Pro device port to the pinned ImmortalWrt source tree.
set -euo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")" && pwd)}"
OPENWRT="${OPENWRT_DIR:-$WORKSPACE/openwrt}"
DEVICE_SOURCE="$WORKSPACE/devices/mt7981b-oraybox-x1-pro-ubootmod.dts"
DEVICE_TARGET="$OPENWRT/target/linux/mediatek/dts/mt7981b-oraybox-x1-pro-ubootmod.dts"
DEVICE_PATCH="$WORKSPACE/patches/0001-mediatek-filogic-add-oray-x1-pro.patch"

if ! git -C "$OPENWRT" rev-parse --git-dir >/dev/null 2>&1; then
	echo "ERROR: ImmortalWrt source tree not found: $OPENWRT" >&2
	exit 1
fi

install -m 0644 "$DEVICE_SOURCE" "$DEVICE_TARGET"

if git -C "$OPENWRT" apply --reverse --check "$DEVICE_PATCH" 2>/dev/null; then
	echo "X1 Pro source patch is already applied"
elif git -C "$OPENWRT" apply --check "$DEVICE_PATCH"; then
	git -C "$OPENWRT" apply "$DEVICE_PATCH"
	echo "Applied X1 Pro source patch"
else
	echo "ERROR: X1 Pro source patch does not apply to the selected source" >&2
	exit 1
fi

# ---- Aurora theme (clone single LuCI package into package/) ----
# eamonxg aurora 是单个 LuCI 包（非 feed，feed 索引器不识别根目录无子包列表的仓库），
# 需 clone 到 package/ 由 buildroot 自动扫描。若 clone 失败仅告警、不阻塞构建：
# 缺包时 make defconfig 会静默丢弃对应 CONFIG_PACKAGE_*=y 符号，固件将不带主题但仍可编译。
for pkg in luci-theme-aurora luci-app-aurora-config; do
	repo="https://github.com/eamonxg/${pkg}.git"
	target="$OPENWRT/package/${pkg}"
	rm -rf "$target"
	if git clone --depth 1 "$repo" "$target"; then
		echo "[ok] cloned ${pkg} into package/"
	else
		echo "WARNING: failed to clone ${pkg} from ${repo}; firmware will build without this theme package" >&2
	fi
done
