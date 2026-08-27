# 发现台账

| ID | 稳定指纹 | 分类 | 置信度/严重度 | 根因与影响 | 状态/验证 |
| --- | --- | --- | --- | --- | --- |
| F-001 | image profile / runtime board / sysupgrade TAR board mismatch | confirmed defect | A/P1 | 未设置 `BOARD_NAME` 会生成设备端拒绝的目录名 | fixed；静态合同已验证，待完整构建 |
| F-002 | device profile / required USB runtime packages / omitted packages | confirmed defect | A/P2 | 设备 profile 丢失 USB3 与 automount | verified；profile 与 manifest 校验均覆盖 |
| F-003 | paired U-Boot 112M layout / produced sysupgrade format / `.itb` instead of NAND TAR | confirmed defect | A/P1 | 新设备定义沿用了 FIT-only 产物覆盖，偏离配套 U-Boot 的原仓库 TAR 流程 | fixed；源码链路已验证，真机构建/刷写 blocked |
| F-004 | GitHub workflow / third-party action / mutable ref and broad token | confirmed defect | A/P1 | 第三方代码与写令牌位于同一 job，且引用可变 | verified；job 权限拆分并固定第三方 SHA |
| F-005 | menuconfig / actor without public SSH key / public tmate session | confirmed defect | A/P1 | action-tmate 默认 `auto` 在无公钥时允许任意持有会话地址者连接 | verified；设置 `limit-access-to-actor: true` 并通过 actionlint/权限流复核 |
| F-006 | release validation / empty or malformed inner images / accepted archive | confirmed defect | B/P2 | 只检查 TAR 成员名，未验证 payload 非空与格式 | verified；增加大小、魔数和解析门禁；真实构建见 blocked COV-14 |
| F-007 | release cleanup / more than CLI default results / older releases unseen | confirmed defect | A/P2 | `gh release list` 默认结果上限导致非全量清理 | verified；REST `--paginate --slurp` 与多页夹具通过 |
| F-008 | workflow cleanup / more than 200 runs / older runs unseen | confirmed defect | A/P2 | `gh run list --limit 200` 人为截断 | verified；REST 全分页夹具通过 |
| F-009 | orphan tag cleanup / non-release repository tags / destructive deletion | confirmed defect | A/P1 | 清理所有无 Release 的 Tag，超出 X1Pro Release 管理范围 | verified；仅查询并二次校验 `X1Pro-*`，前缀/Release 夹具通过 |
| F-010 | cleanup deletion / API failure / workflow reports success | confirmed defect | A/P2 | 删除错误被吞掉，技术成功掩盖实际失败 | verified；累计失败并非零退出，三类删除失败夹具通过 |
| F-011 | HomeProxy TUN mode / `ip tuntap` / no iproute2 full implementation | confirmed defect | A/P2 | 精简 diffconfig 丢失旧配置中的 `ip-full`；BusyBox `ip` 不支持 HomeProxy TUN 模式调用的 `tuntap` | verified；显式补包，固定 feeds `make defconfig` 与 manifest 门禁均覆盖 |
| F-012 | device packages / automount restored / README says USB removed | confirmed defect | A/P3 | 文档与设备 profile 及 automount 依赖闭包不一致 | verified；固件内容说明已同步 |
| F-013 | workflow cleanup / numeric input zero / expression fallback to seven | confirmed defect | A/P2 | GitHub 表达式把数值 0 视为 falsy，导致 UI 声明的全删模式无法触发 | verified；Shell 空值默认与 retain=0 夹具通过 |
| F-014 | delete-tags job / skipped dependency / implicit success guard | confirmed defect | A/P2 | 默认仅清 Tag 时依赖 release job 为 skipped，未使用状态函数会被隐式 `success()` 阻止 | verified；`!cancelled()` 显式状态条件与 skipped 夹具通过 |
| F-015 | menuconfig / workflow_dispatch tag ref / push as branch | confirmed defect | A/P2 | Tag ref 可进入会话，但保存步骤把 ref 名当分支 pull/push，可能失败或语义错误 | verified；非 branch ref 先明确失败，分支/tag 夹具通过 |
| F-016 | release cleanup / invalid published_at / silent skip | confirmed defect | A/P2 | 日期解析失败被跳过却仍报告清理成功 | verified；计入失败并非零退出，异常日期夹具通过 |
| F-017 | cleanup retention / negative or fractional value / expanded deletion scope | confirmed defect | A/P1 | 未验证天数；负数生成未来 cutoff，可能扩大到近乎全量删除 | verified；任何 API 前只接受非负整数，无效输入夹具通过 |
| F-018 | workflow cleanup / completed nonstandard conclusions / never age out | confirmed defect | A/P2 | 正保留期只枚举少数结论，neutral/stale 等完成记录永不清理，失败类也漏项 | verified；所有 completed 按年龄清理，失败类完整夹具通过 |
| F-019 | cancellation / destructive post-job cleanup / still starts | confirmed defect | A/P1 | `always()` 允许取消后继续启动 Tag/run 删除 | verified；改为 `!cancelled()`，actionlint 与条件复核通过 |
| F-020 | post-build third-party cleanup / deletion errors swallowed and all workflows in scope | confirmed defect | A/P1 | 固定 Action 逐条失败仍成功，且默认遍历仓库所有 workflow | verified；本地分页脚本只处理当前 workflow 并传播失败，夹具通过 |
| F-021 | SquashFS validation / superblock-only `-s` / truncated root accepted | confirmed defect | A/P1 | `unsquashfs -s` 只读 superblock，保留头部的截断镜像仍可通过 | verified；完整解包有效样本通过、截断样本失败；rc=2 仅按工具语义屏蔽非致命节点告警 |
| F-022 | HomeProxy runtime contract / commands and ucode imports / not release-gated | confirmed risk | A/P2 | 脚本直接使用 `wget`、`jsonfilter`、JSON `nft` 与 `fs/ubus/uci`，虽由当前传递依赖选中但原门禁未核对 | verified；扩展 defconfig/manifest 门禁，固定 feeds 24 项检查通过 |
| F-023 | orphan tag cleanup / release snapshot then tag delete / cross-API TOCTOU | residual platform risk | C/P3 | Release 列举与 Tag 删除是两个 GitHub API 操作，期间极窄窗口内新建同名 Release 可能竞态 | accepted residual；GitHub 无原子“仅当无 Release 时删除 Tag”接口；已用 `X1Pro-*` 范围、Release 快照和失败传播降低风险 |

## 影响消费者

- F-001/F-003/F-006：构建 artifact、GitHub Release、U-Boot Web 升级和后续 Linux sysupgrade。
- F-004/F-005：手动 menuconfig 与保存配置到默认分支。
- F-007/F-009/F-010/F-014/F-016/F-017/F-019：Release、Release Tag 和普通维护 Tag。
- F-008/F-010/F-013/F-017/F-018/F-020：GitHub Actions 历史运行记录。
- F-011/F-022：HomeProxy 的 TProxy/TUN、资源更新、订阅更新与防火墙生成路径。
- F-012：固件内容说明和用户对 USB 存储能力的预期。
- F-021：任何准备上传为 artifact/Release 的 SquashFS rootfs。
- F-023：仅独立维护工作流清理 `X1Pro-*` 孤立 Tag 的瞬间竞态窗口。
