#!/bin/sh
# fix-sysupgrade.sh — 修复 oray,x1pro-v1-ubootmod 系统内升级失败
#
# 根因: 该机型 U-Boot 未在设备树 chosen 节点设置 rootdisk 属性 ->
#   /lib/upgrade/fit.sh 的 export_fitblk_bootdev() 检测失败 ->
#   fit_do_upgrade 在写入前 return 1 -> 固件升级静默中止 (Web/SSH 升级"没反应")。
# 本脚本把 fit.sh 补成 fallback 版本, 之后升级即可正常写入。
#
# 用法:
#   sh /etc/fix-sysupgrade.sh                 # 仅修补 fit.sh, 然后去 Web 上传固件即可
#   sh /etc/fix-sysupgrade.sh /tmp/xxx.bin    # 修补后立即 sysupgrade 该固件 (保留配置)
#   sh /etc/fix-sysupgrade.sh --status        # 仅查看当前 fit.sh 是否已修复
#
# 说明:
#   - 幂等: 已修复则无需处理, 不会重复改。
#   - 下次用已修复 diy-part1.sh 重新编译的固件会自带修复, 本脚本届时无需使用。

FIT_SH="/lib/upgrade/fit.sh"
TAG="fit-fix"
BAD='\[ -n "\$CI_METHOD" \] || return 1'
GOOD='\[ -n "\$CI_METHOD" \] || { CI_METHOD="ubi"; CI_UBIPART="ubi"; CI_KERNPART="kernel"; CI_ROOTPART="rootfs"; }'

is_fixed() {
    [ -f "$FIT_SH" ] && grep -q 'CI_ROOTPART="rootfs"' "$FIT_SH" 2>/dev/null
}

patch_fit() {
    if [ ! -f "$FIT_SH" ]; then
        echo "[跳过] 未找到 $FIT_SH, 当前固件可能不使用 fit 升级方案"
        return 0
    fi
    if grep -q "$BAD" "$FIT_SH"; then
        sed -i "s/$BAD/$GOOD/" "$FIT_SH"
        if is_fixed; then
            logger -t "$TAG" "patched $FIT_SH for sysupgrade"
            echo "[已修复] fit.sh 已修补, 现在可以正常升级固件了"
            return 0
        else
            echo "[失败] 修补未生效, 请手动检查 $FIT_SH"
            return 1
        fi
    else
        echo "[无需处理] fit.sh 已是修复版 (或不存在此问题)"
        return 0
    fi
}

case "${1:-}" in
    --status)
        if is_fixed; then
            echo "状态: fit.sh 已修复 -> 可正常升级"
        else
            echo "状态: fit.sh 仍为旧版 -> 升级会静默失败, 请运行: sh $0"
        fi
        ;;
    "")
        patch_fit
        ;;
    -*)
        echo "用法: sh $0 [固件路径 | --status]"
        exit 1
        ;;
    *)
        FIRMWARE="$1"
        if [ ! -f "$FIRMWARE" ]; then
            echo "[错误] 固件文件不存在: $FIRMWARE"
            exit 1
        fi
        patch_fit || exit 1
        echo "[执行] sysupgrade $FIRMWARE (保留配置) ..."
        sysupgrade "$FIRMWARE"
        ;;
esac
