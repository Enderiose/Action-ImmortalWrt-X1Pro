# Restore X1 Pro sysupgrade.bin

## 目标与非目标

- 将 X1 Pro 构建产物从统一 FIT `sysupgrade.itb` 恢复为原仓库使用的
  sysupgrade TAR `sysupgrade.bin`。
- 保留 ImmortalWrt `v25.12.1`、HomeProxy 精简配置、X1 Pro 112 MiB UBI
  分区布局及现有 MAC/Wi-Fi 校准定义。
- 不修改或构建 BL2/FIP，不更换 U-Boot，不引入双格式构建或兼容分支。

## 当前理解

- `.itb` 与 `.bin` 不是只差扩展名：当前 `.itb` 是包含内核和 rootfs 的统一 FIT，
  原仓库 `.bin` 是包含 `kernel`、`rootfs` 和控制信息的 sysupgrade TAR。
- 配套 `bl-mt798x-dhcpd` 的 Web 升级代码可解析 sysupgrade TAR 并写入 UBI 的
  `kernel`/`rootfs` 卷；其部分 TFTP 菜单通过 `iminfo` 只接受原始 FIT，不能把
  `.bin` 当作 `.itb` 使用。
- 恢复 `.bin` 需要同时调整镜像配方、DTS 的 `fit` 根盘声明、平台镜像校验和
  GitHub Actions 产物选择。

## 实施计划

1. 核对固定 ImmortalWrt `v25.12.1` 的 filogic 默认内核与 sysupgrade 配方。
2. 将 X1 Pro 设备配方改为 `sysupgrade-tar | append-metadata`，恢复独立
   `kernel`/`rootfs` UBI 卷语义。
3. 从 X1 Pro DTS 移除统一 FIT 专用的 `/dev/fit0`、`rootdisk` 和预定义 `fit` 卷。
4. 让平台升级显式按 NAND UBI 的 `kernel`/`rootfs` 卷处理，并让通用 NAND
   校验识别外层 sysupgrade TAR。
5. 将 Workflow 的查找、上传、发布说明和 README 全部改为 `.bin`。

## 验证计划

- 运行 `bash -n diy-part1.sh` 和 `git diff --check`。
- 将移植脚本应用到固定 commit 的干净 ImmortalWrt `v25.12.1` 源码，确认补丁可
  正向应用且二次运行保持幂等。
- 检查最终设备定义只生成 `sysupgrade.bin`，且 DTS 不再包含统一 FIT 根盘节点。
- 检查 Workflow 只收集并发布 X1 Pro 的 `.bin` 产物。
- 完整固件编译由 GitHub Actions 执行；本机若缺少 Linux/OpenWrt 构建环境，则
  明确记录为未运行。

## 风险与影响

- `.bin` 应通过 ImmortalWrt/LuCI `sysupgrade` 或支持 sysupgrade TAR 的 U-Boot Web
  升级入口刷写；不能送入要求 `iminfo` 成功的原始 FIT TFTP 入口。
- 从现有单一 `fit` 卷切回 `kernel`/`rootfs` 卷会重建 UBI 生产卷；首次切换前必须
  备份配置及 NAND 关键分区，并准备串口/恢复手段。
- 仅恢复外层发布格式，不改变设备当前固定源码版本和分区边界。

## 执行调整

- 已确认 ImmortalWrt `v25.12.1` 的 MediaTek 默认 `KERNEL` 配方会生成带设备树的
  FIT 内核，默认产物也是 `sysupgrade.bin`；设备定义只需覆盖为
  `sysupgrade-tar | append-metadata`，不再保留统一 FIT 专用配方。
- 已对照原仓库 `openwrt-24.10-6.6` 的 X1 Pro 定义，恢复其
  `IMAGE_SIZE := 114688k`、`KERNEL_IN_UBI := 1` 和 sysupgrade TAR 语义。
- 当前 25.12 的 `fit_do_upgrade` 依赖 DTS `rootdisk`；恢复老版 DTS 后改为显式
  `nand_do_upgrade`，避免升级路径继续依赖已移除的 `fit` 卷。
- 移植补丁已在固定 commit `a3378d1a2c15beb2faf4b0bce9c00f07143efa29` 上
  正向应用，二次运行通过反向检查识别为已应用；应用后的源码通过
  `git diff --check`。
- 本机仅有 GNU Make 3.81，未在 macOS 上执行 OpenWrt 全量构建；最终产物结构仍需
  由 GitHub Actions 的 Linux 构建确认。
