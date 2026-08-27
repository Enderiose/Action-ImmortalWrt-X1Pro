# X1 Pro HomeProxy 25.12 精简固件

## 目标与非目标

- 目标：在独立分支中将构建源固定到 ImmortalWrt 最新稳定版 `v25.12.1`。
- 目标：为官方源码补入 Oray X1 Pro v1 的 U-Boot-mod 设备支持，生成适配 FIT/UBI 启动方式的 sysupgrade 固件。
- 目标：最终固件只保留基础路由、LuCI 中文界面和 HomeProxy 所需组件，移除 NPC、Bandix、OpenClash、PassWall、Ruby 等非必要预装内容。
- 目标：更新工作流、文档和产物命名，并执行与修改范围相符的静态与配置验证。
- 目标：删除已退出当前构建路径的旧配置与 VPN/兼容覆盖目录，避免后续误用。
- 目标：修复 SSH/menuconfig 调试与固件构建并行运行，避免同一次工作流构建或发布修改前的配置。
- 非目标：构建或刷写 BL2/FIP、修改 Factory/bdinfo 数据、推送远端分支、替用户执行真机刷写。
- 非目标：新增 HomeProxy 之外的代理方案、额外主题、监控或存储服务。

## 当前理解

- 当前构建基于 `yvzz/immortalwrt-mt798x-6.6` 的 `openwrt-24.10-6.6` 分支；该 fork 没有 25.12 分支。
- 官方 ImmortalWrt 当前稳定版本为 `v25.12.1`，但官方树没有 Oray X1 Pro 设备定义，需要移植原设备的分区、MAC、Wi-Fi 校准及升级声明。
- X1 Pro 的原设备布局为：BL2 1 MiB、env 512 KiB、Factory 2 MiB、FIP 2 MiB、bdinfo 512 KiB、kpanic 2 MiB、UBI 112 MiB；Factory 必须保持只读且不得写入。
- 相邻 U-Boot 仓库的近期 X1 Pro U-Boot-mod 环境以 UBI `fit` 卷和 `.itb` 升级文件启动；兼容性取决于设备实际刷入的 FIP 版本和 `mtdparts` 是否确为 X1 Pro 112 MiB 布局。
- HomeProxy 的核心依赖由包声明带入（包括 sing-box、firewall4、nftables TProxy 相关模块），Ruby 不是其依赖。

## 实施计划

1. 固定官方源码仓库与 `v25.12.1` 标签，删除多代理构建矩阵和旧版本专用 workaround。
2. 增加可重复应用的 X1 Pro DTS 与源码补丁，采用官方 25.12 的 FIT sysupgrade 格式，同时保留 X1 Pro 原分区和校准数据位置。
3. 将配置改成单一的 HomeProxy 精简 diffconfig，只显式启用设备、LuCI、中文和 HomeProxy。
4. 删除固件 overlay 中的 NPC 服务、配置和防火墙规则，保留 Web 上传大小修正。
5. 更新工作流产物筛选、发布说明和 README。
6. 删除旧的通用、OpenClash、PassWall、VPN 配置，以及不再引用的 VPN overlay 和 LuCI 兼容包；README 不再将其描述为历史资料。
7. 手动启用 SSH/menuconfig 时只运行配置调试任务；保存配置后由后续工作流运行执行构建。

## 验证计划

- 用 `git apply --check` 在干净的官方 `v25.12.1` 源码上验证设备补丁。
- 运行 `actionlint`、Shell 语法检查和工作流 YAML 解析，确认 SSH 模式不会同时运行构建任务。
- 在官方源码上更新/安装 feeds，运行 `make defconfig`，确认目标设备、HomeProxy 及其关键依赖进入最终配置，并确认 Ruby/NPC/Bandix 未启用。
- 检查补丁中的分区偏移、Factory 只读属性、MAC/EEPROM 地址和 FIT 产物名称。
- 搜索构建路径，确认工作流不再引用已删除的旧配置及覆盖目录；README 可以保留组件移除说明。
- 对仓库中非补丁文件运行 `git diff --check`；补丁文件单独在干净源码上应用，并对应用结果运行 `git diff --check`，避免把统一补丁的上下文标记误判为源码空白错误。
- 不在本机执行完整固件编译；完整编译交由 GitHub Actions，最终明确标注未运行状态。

## 风险与影响

- 设备支持属于跨大版本移植；即使配置验证通过，首次刷写仍应通过恢复环境进行，并提前完整备份 BL2、FIP、Factory、bdinfo 和全盘 NAND。
- 如果设备实际 U-Boot 仍期待旧式 tar `.bin`，或其 FIP 分区布局不是 `x1pro-mod-112m`，新 `.itb` 不能直接使用；刷写前必须核对 U-Boot 环境。
- 当前 U-Boot 源码的默认布局是双 56 MiB UBI；切换到本固件要求的单 112 MiB UBI 会使现有 UBI 数据失效，必须先备份并准备恢复刷写。
- 精简会移除 USB 存储、旧 iptables 兼容、额外 VPN/代理、NPC 和第三方主题等预装能力，后续有需要应按空间余量单独安装。

## 执行调整

- 为便于审核设备树，把新增 DTS 作为独立源文件保存，针对官方树既有文件的修改保留为小型补丁；构建脚本会同时复制 DTS 并应用补丁。
- 当前 U-Boot 仓库的 X1 Pro multi-layout DTS 声明 FIP 位于 `0x380000`，但 2025 ATF 配置覆盖为 `0x3c0000`。本任务不构建或刷写引导固件，并在 README 中明确记录该上游风险。
- macOS 自带 Make 3.81、Bash 3.2 和 awk 无法运行官方 25.12 配置工具；未安装宿主机依赖，改用一次性 Debian 容器完成 feeds 与 `make defconfig` 验证。
- 用户确认完整固件编译使用 GitHub Actions；本地验证止于补丁、工作流和最终配置展开，不运行完整 toolchain/固件构建。
- 用户要求清理不再使用的配置以避免误用；删除范围限定为旧配置、`files-vpn/` 与未引用的 `package/luci-compat-keep/`，不删除与配置选择无关的图片资源。
- 复核发现 GitHub Actions 的 job 默认并行运行；工作流在手动 `ssh=true` 时跳过 `build`，防止构建及发布 menuconfig 修改前的配置。
- 新增的统一补丁包含以空格开头的上下文行，仓库级 `git diff --check` 会把这些补丁语法标记报告为空白问题；验证改为检查非补丁差异，并在干净源码应用补丁后检查实际源码差异。

## 验证结果

- 通过：X1 Pro 补丁在干净的官方 `v25.12.1` 源码上执行 `git apply --check`。
- 通过：设备移植脚本首次应用和重复执行幂等验证。
- 通过：Debian 容器内完成固定 feeds 安装和 `make defconfig`；目标设备、HomeProxy、sing-box、firewall4、nftables TProxy 依赖均已选中。
- 通过：最终配置未选中 Ruby、NPC、Bandix、Aurora、USB 存储、WireGuard、ttyd、UPnP 或旧 iptables 软件包。
- 通过：`actionlint`、YAML 解析和 Shell 语法检查；已断言仅手动 `ssh=true` 跳过构建，正常手动、定时和 repository dispatch 仍执行构建。
- 通过：非补丁文件的 `git diff --check`，以及补丁应用后官方源码的 `git diff --check`；未将统一补丁上下文标记产生的仓库级提示记为通过。
- 通过：旧配置、`files-vpn/` 和 `package/luci-compat-keep/` 均已删除；构建路径无残留引用，工作流只引用 `config/x1pro-homeproxy.config`，README 仅保留组件移除说明。
- 未运行：完整 ImmortalWrt 固件编译和真机刷写验证，交由 GitHub Actions 与用户设备完成。
