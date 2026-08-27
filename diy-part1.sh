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
