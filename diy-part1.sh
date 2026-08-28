#!/bin/bash
# DIY Part 1: X1 Pro device setup
# 原则：最小化侵入，只 patch 不改写上游文件
# 幂等设计：重复运行不会重复追加条目
# 参考 TR3000：第三方包直接 clone 到 package/，不用 feeds
set -euo pipefail

WORKSPACE="$GITHUB_WORKSPACE"
OPENWRT="$WORKSPACE/openwrt"

echo "=== DIY Part 1: X1 Pro setup ==="

# 1. Clone third-party packages into package/ (参照 TR3000)
#    直接 clone 避免 feeds 分支/index 问题
mkdir -p "$OPENWRT/package"
for repo in luci-theme-aurora luci-app-aurora-config luci-app-bandix openwrt-bandix; do
  if [ -d "$OPENWRT/package/$repo" ]; then
    echo "  → $repo already exists, skipping clone"
  else
    case "$repo" in
      luci-theme-aurora)      url="https://github.com/eamonxg/luci-theme-aurora" ;;
      luci-app-aurora-config) url="https://github.com/eamonxg/luci-app-aurora-config" ;;
      luci-app-bandix)        url="https://github.com/timsaya/luci-app-bandix" ;;
      openwrt-bandix)         url="https://github.com/timsaya/openwrt-bandix" ;;
    esac
    git clone --depth=1 "$url" "$OPENWRT/package/$repo"
  fi
done
echo "  → aurora packages cloned"

# 1b. Fix bandix Makefile: 将 zoneinfo-all 改为 zoneinfo-asia（.config 已启用）
BANDIX_MK="$OPENWRT/package/openwrt-bandix/openwrt-bandix/Makefile"
if [ -f "$BANDIX_MK" ]; then
  if grep -q 'zoneinfo-all' "$BANDIX_MK"; then
    sed -i 's/zoneinfo-all/zoneinfo-asia/g' "$BANDIX_MK"
    echo "  → bandix Makefile: zoneinfo-all → zoneinfo-asia"
  else
    echo "  → bandix Makefile: already updated or no zoneinfo dep"
  fi
fi

# 2. Fix sysupgrade failure on oray,x1pro-v1-ubootmod
#    U-Boot 未在设备树 chosen 节点设置 rootdisk 属性,
#    导致 export_fitblk_bootdev() 检测失败 → CI_METHOD 为空 → fit_do_upgrade return 1 → 固件未写入.
#    补丁: CI_METHOD 为空时 fallback 到 UBI 默认参数 (ubi/kernel/rootfs).
#    关键: 源码树里存在【多个】fit.sh:
#      - 通用 OpenWrt fit.sh (package/feeds base-files, 不含 export_fitblk_bootdev, 补丁对其无效)
#      - mt798x 专用 fit.sh (含 export_fitblk_bootdev + CI_METHOD, 才是本机真正的升级逻辑)
#    必须定位到【含 export_fitblk_bootdev】的那个并打补丁, 否则会命中通用版而静默跳过.
FIT_SH=""
for cand in \
  "$OPENWRT/target/linux/mediatek/base-files/lib/upgrade/fit.sh" \
  "$OPENWRT/target/linux/mediatek/filogic/base-files/lib/upgrade/fit.sh" \
  "$OPENWRT/target/linux/mediatek/mt798x/base-files/lib/upgrade/fit.sh" \
  "$OPENWRT/package/base-files/files/lib/upgrade/fit.sh" \
  "$OPENWRT/feeds/base-files/files/lib/upgrade/fit.sh" ; do
  if [ -f "$cand" ] && grep -q "export_fitblk_bootdev" "$cand"; then
    FIT_SH="$cand"; break
  fi
done
# 兜底: 全盘搜索含 export_fitblk_bootdev 的 fit.sh (排除 build_dir / staging_dir 产物)
if [ -z "$FIT_SH" ]; then
  FIT_SH=$(find "$OPENWRT" -name fit.sh \
    -not -path "*/build_dir/*" -not -path "*/staging_dir/*" 2>/dev/null \
    -exec grep -l "export_fitblk_bootdev" {} \; | head -1)
fi

if [ -n "$FIT_SH" ]; then
  if grep -q 'CI_ROOTPART="rootfs"' "$FIT_SH"; then
    echo "  → fit.sh: already patched ($FIT_SH)"
  else
    sed -i 's/\[ -n "\$CI_METHOD" \] || return 1/[ -n "$CI_METHOD" ] || { CI_METHOD="ubi"; CI_UBIPART="ubi"; CI_KERNPART="kernel"; CI_ROOTPART="rootfs"; }/' "$FIT_SH"
    if grep -q 'CI_ROOTPART="rootfs"' "$FIT_SH"; then
      echo "  → fit.sh: patched ($FIT_SH)"
    else
      echo "  → [WARN] fit.sh patch failed (pattern not found in $FIT_SH)"
    fi
  fi
else
  echo "  → [WARN] fit.sh not found (含 export_fitblk_bootdev), skipping sysupgrade fix"
fi

# DTS/filogic.mk/02_network/platform.sh/MAC fix 已全部集成至上游源码
# 仓库路径: yvzz/immortalwrt-mt798x-6.6 openwrt-24.10-6.6 branch
# 无需本地 patch

# ---- Toolchain off64_t fix: generate quilt patches (replaces workflow sed) ----
# musl 1.2.x 废弃了 off64_t/fseeko64；binutils readelf.c 和 GCC 源码需要 patch
# 生成 quilt patch 放到 toolchain patches 目录，让 make prepare 自动应用
# 替代 workflow 里的运行时 sed，避免破坏 ccache 命中
# 注意：此逻辑在 .config 加载后运行（make defconfig 之前），make 能识别 binutils/GCC 版本

# binutils readelf.c off64_t fix
BINUTILS_PATCH_DIR="$OPENWRT/toolchain/binutils/patches/2.42"
if [ ! -f "$BINUTILS_PATCH_DIR/999-off64t-musl-fix.patch" ]; then
  mkdir -p "$BINUTILS_PATCH_DIR"
  make -C "$OPENWRT" toolchain/binutils/prepare V=s 2>/dev/null || true
  for rf in "$OPENWRT"/build_dir/toolchain-*/binutils-2.42/binutils/readelf.c; do
    [ -f "$rf" ] || continue
    (
      cd "$(dirname "$(dirname "$rf")")"
      cp binutils/readelf.c binutils/readelf.c.orig
      sed -i 's/off64_t/off_t/g; s/fseeko64/fseeko/g' binutils/readelf.c
      diff -u binutils/readelf.c.orig binutils/readelf.c 2>/dev/null \
        | sed -e 's/\.orig//' -e 's|^--- |--- a/|' -e 's|^+++ |+++ b/|' \
        > "$BINUTILS_PATCH_DIR/999-off64t-musl-fix.patch" || true
      rm -f binutils/readelf.c.orig
    )
    rm -rf "$OPENWRT"/build_dir/toolchain-*/binutils-2.42
    rm -f "$OPENWRT"/build_dir/toolchain-*/.binutils-*
    echo "[ok] generated binutils off64_t quilt patch"
    break
  done
fi

# GCC off64_t fix (libcpp/files.c, gcc/genhooks.c, gcc/system.h)
GCC_PATCH_DIR="$OPENWRT/toolchain/gcc/patches/13.3.0"
if [ ! -f "$GCC_PATCH_DIR/999-off64t-musl-fix.patch" ]; then
  mkdir -p "$GCC_PATCH_DIR"
  make -C "$OPENWRT" toolchain/gcc/initial/prepare V=s 2>/dev/null || true
  GCC_PATCH_FILE="$GCC_PATCH_DIR/999-off64t-musl-fix.patch"
  : > "$GCC_PATCH_FILE"
  for gf in "$OPENWRT"/build_dir/toolchain-*/gcc-13.3.0; do
    [ -d "$gf" ] || continue
    (
      cd "$gf"
      for f in libcpp/files.c gcc/genhooks.c gcc/system.h; do
        [ -f "$f" ] || continue
        cp "$f" "$f.orig"
        sed -i 's/off64_t/off_t/g; s/fseeko64/fseeko/g' "$f"
        diff -u "$f.orig" "$f" 2>/dev/null \
          | sed -e 's/\.orig//' -e 's|^--- |--- a/|' -e 's|^+++ |+++ b/|' \
          >> "$GCC_PATCH_FILE" || true
        rm -f "$f.orig"
      done
    )
    rm -rf "$OPENWRT"/build_dir/toolchain-*/gcc-13.3.0
    rm -f "$OPENWRT"/build_dir/toolchain-*/.gcc-*
    echo "[ok] generated GCC off64_t quilt patch"
    break
  done
fi

echo "=== DIY Part 1 done ==="
