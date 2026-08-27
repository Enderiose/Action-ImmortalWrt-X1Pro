# 审查轮次

## Round 1 — 已知问题修复波次

- revision_start: `f528d12` + 当前工作树
- coverage_total: 13
- coverage_terminal: 5
- coverage_pending/fixed: 6
- blocked: 2
- confirmed: P1 5，P2 5
- fixed: 10
- verified: 3
- rejected/not-applicable: 3
- verification_passed: actionlint、YAML 解析、非补丁文件 whitespace 检查、上游静态对照
- verification_failed: 0
- verification_unexecuted: 完整 GitHub 构建、真实设备刷写
- next_scope: 修正严格错误模式边界，运行 Shell/JSON/固件夹具、补丁应用与第二轮独立复核

## Round 2 — 清理安全与产物完整性挑战

- revision_start: `f528d12` + Round 1 工作树
- new_confirmed: F-014 至 F-021，其中 P1 4、P2 4
- root_causes_fixed: skipped dependency 隐式成功条件、Tag ref 保存、日期/保留值失效、结论枚举、取消后破坏性任务、第三方删除失败吞噬、SquashFS 仅检查 superblock
- verification_passed: actionlint；多页/边界/失败传播夹具；实际 SquashFS 有效与截断样本；固定源码补丁应用
- verification_failed: 初版完整解包在非 root 设备节点返回 rc=2；按 SquashFS 4.7.4 明确语义加入 `-no-exit-code` 后，rc=1 损坏样本仍失败
- verification_unexecuted: 完整 GitHub 构建、真实 Release、真实设备刷写
- next_scope: HomeProxy 实际脚本运行时闭包与最终全树复核

## Round 3 — HomeProxy 运行时闭包

- revision_start: `f528d12` + Round 2 工作树
- new_confirmed: F-022（P2）；new_P0/P1: 0
- evidence: 固定 luci feed 的 HomeProxy 脚本直接调用 `wget`/`jsonfilter`/`nft`，并导入 `fs`/`ubus`/`uci`
- fix: 不复制整棵传递依赖到 diffconfig；把六个关键运行时包加入 defconfig 和最终 manifest 门禁
- verification_passed: Debian/glibc 干净容器 `make defconfig`，24 个目标/直接/关键运行时配置全部为 `y`
- verification_failed: 首次 Alpine/musl 运行无法执行 glibc host tool；首次 Debian 重试受临时源码残留 x86 host cache 影响；隔离缓存后发现容器缺 wget/distutils；补齐一次性容器前置后通过
- verification_unexecuted: 完整包编译与最终真实 manifest（由远端完整构建产生）
- next_scope: 独立挑战者与主审最终复扫，要求连续第二轮无新增 P0/P1

## Round 4 — 独立挑战与最终复扫

- revision_start: `f528d12` + Round 3 工作树
- independent_challengers: 两名只读复核者分别检查设备补丁、三个 workflow、HomeProxy 新门禁、清理夹具和 SquashFS 正反样本，均未发现新的确定 P0/P1/P2
- root_rescan: 复核最终 diff、NAND `platform_check_image` 默认分派、job 条件/权限、HomeProxy 固定 feeds 实际调用与验证输出，未发现新的 P0/P1/P2
- new_confirmed: F-023（P3 外部跨 API 竞态）；new_P0/P1: 0
- verification_passed: actionlint；3 个 YAML 与 18 个 run block；Shell；whitespace；干净固定源码补丁应用/反向检查/DTS 对比；15 组清理夹具；HomeProxy 24 项 defconfig；SquashFS 正反样本
- verification_failed: 0（环境准备阶段的失败已在 Round 3 单列，最终命令均通过）
- blocked: 完整 GitHub 固件构建/真实 Release；真实设备 U-Boot 环境、刷写和启动
- convergence: Round 3 与 Round 4 连续无新增 P0/P1，已满足本次声明范围的收敛条件
