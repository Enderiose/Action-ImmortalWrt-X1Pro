# 审查覆盖台账

## 范围与依据

- 范围：仓库内的 X1 Pro 设备 DTS、ImmortalWrt 补丁、构建配置、feeds、辅助脚本、三个 GitHub Actions 工作流和直接相关 README。
- 权威顺序：用户明确要求与原仓库产物行为；固定的 ImmortalWrt `v25.12.1`/commit；配套 U-Boot multi-layout 源码；仓库当前配置与 README。
- 排除：完整 ImmortalWrt 上游实现、GitHub 平台本身、未连接的真实 X1 Pro 设备和设备当前保存的 U-Boot 环境。
- 前端平台审查：不适用；仓库不包含 Web、移动端或桌面 UI，图片仅为说明素材。
- 检查基线：`f528d12`，分支 `main`，并包含当前未提交修复。

## 覆盖项

| ID | 模块/表面 | 验证级别 | 状态 | 证据或阻塞原因 | 关联发现 |
| --- | --- | --- | --- | --- | --- |
| COV-01 | 固定 ImmortalWrt 源码与 feeds | 静态 | verified | source/feed commit 均固定；工作流校验源码 HEAD；干净容器使用相同 commit | F-004 |
| COV-02 | DTS、NAND 分区、MAC、USB 定义 | 静态/上游对照 | verified | 与原设备定义及配套 U-Boot 112 MiB 布局逐项对照 | F-002, F-003 |
| COV-03 | 设备补丁应用与 sysupgrade 分派 | 干净 clone 补丁应用/反向检查 | verified | 固定 source commit 上 `git apply --check`、应用、反向检查和 DTS `cmp` 均通过 | F-001, F-003 |
| COV-04 | HomeProxy diffconfig 与 Kconfig 依赖闭包 | 固定 feeds + Linux 容器 `make defconfig` | verified | 24 个目标/直接/关键运行时配置均为 `y` | F-011, F-022 |
| COV-05 | 产物选择、TAR 板名、metadata 与 manifest | 静态/合同检查 | verified | 唯一 `.bin`、精确成员、BOARD、metadata 和关键 package 门禁已审阅；真实产物由 COV-12 阻塞 | F-001, F-003, F-006, F-022 |
| COV-06 | FIT kernel 与 SquashFS root 校验 | 实际工具正反样本 | verified | FIT 魔数/`mkimage -l`；完整 SquashFS 解包有效样本通过、截断样本失败 | F-006, F-021 |
| COV-07 | 手动 menuconfig、tmate、配置保存 | actionlint/静态权限流/分支夹具 | verified | job 权限隔离、actor SSH key、分支/tag ref 行为均通过 | F-004, F-005, F-015 |
| COV-08 | artifact、Release 与 Release notes | actionlint/静态数据流 | verified | build outputs、artifact 名称、`.bin` 下载/发布链路一致；未创建真实 Release | F-003, F-004 |
| COV-09 | Release/孤立 Tag 清理 | 多页 JSON/API 失败夹具 | verified | 分页、0/正数/无效输入、异常日期、前缀、删除失败均通过；跨 API 原子性限制见 F-023 | F-007, F-009, F-010, F-014, F-016, F-017, F-019, F-023 |
| COV-10 | 全仓库 Workflow run 清理 | 多页/全部 conclusion/API 失败夹具 | verified | 全分页、0/正数/无效输入、结论、去重、删除失败均通过 | F-008, F-010, F-013, F-017, F-018 |
| COV-11 | 当前构建 workflow 的 run 清理 | 多页/保留 10/失败夹具 | verified | 仅当前 workflow、排除当前与未完成、保留最新 10、失败传播均通过 | F-019, F-020 |
| COV-12 | `diy-part1.sh`、uci-defaults 与工作流 Shell | `bash -n`/`sh -n`/YAML run-block `bash -n` | verified | 18 个工作流 run block 和两个仓库脚本通过 | - |
| COV-13 | README 刷写、迁移和风险说明 | 最终静态对照 | verified | `.bin` TAR、卷名、FIT 专用入口限制、USB 与 FIP 风险均与实现一致 | F-003, F-012 |
| COV-14 | GitHub Actions 真实 Ubuntu 完整固件构建/发布 | 动态 | blocked | 已验证 Linux `make defconfig`，但未触发耗时的完整远端编译或真实 Release | F-006 |
| COV-15 | 真实设备 U-Boot 保存环境与刷写启动 | 真机 | blocked | 无设备控制台和当前环境转储；仓库无法替代真机确认 | F-003 |
