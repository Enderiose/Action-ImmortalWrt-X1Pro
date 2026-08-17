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
#    U-Boot 2025.07 未在设备树 chosen 节点设置 rootdisk 属性,
#    导致 export_fitblk_bootdev() 检测失败 → fit_do_upgrade return 1 → 固件未写入.
#    补丁: rootdisk 缺失时 fallback 到 UBI 默认参数 (ubi/kernel/rootfs).
#    注意: fit.sh 路径因 OpenWrt 版本/分支而异, 用候选路径 + 全盘兜底搜索.
FIT_SH=""
for cand in \
  "$OPENWRT/package/base-files/files/lib/upgrade/fit.sh" \
  "$OPENWRT/target/linux/mediatek/base-files/lib/upgrade/fit.sh" \
  "$OPENWRT/feeds/base-files/files/lib/upgrade/fit.sh" ; do
  [ -f "$cand" ] && { FIT_SH="$cand"; break; }
done
# 兜底: 全盘搜索 (排除 build_dir / staging_dir 产物)
if [ -z "$FIT_SH" ]; then
  FIT_SH=$(find "$OPENWRT" -path "*/lib/upgrade/fit.sh" \
    -not -path "*/build_dir/*" -not -path "*/staging_dir/*" 2>/dev/null | head -1)
fi

if [ -n "$FIT_SH" ]; then
  if grep -q 'CI_ROOTPART="rootfs"' "$FIT_SH"; then
    echo "  → fit.sh: already patched ($FIT_SH)"
  else
    sed -i 's/\[ -n "\$CI_METHOD" \] || return 1/[ -n "$CI_METHOD" ] || { CI_METHOD="ubi"; CI_UBIPART="ubi"; CI_KERNPART="kernel"; CI_ROOTPART="rootfs"; }/' "$FIT_SH"
    if grep -q 'CI_ROOTPART="rootfs"' "$FIT_SH"; then
      echo "  → fit.sh: patched ($FIT_SH)"
    else
      echo "  → [WARN] fit.sh patch failed (pattern not found)"
    fi
  fi
else
  echo "  → [WARN] fit.sh not found, skipping sysupgrade fix"
fi

# DTS/filogic.mk/02_network/platform.sh/MAC fix 已全部集成至上游源码
# 仓库路径: yvzz/immortalwrt-mt798x-6.6 openwrt-24.10-6.6 branch
# 无需本地 patch

echo "=== DIY Part 1 done ==="
