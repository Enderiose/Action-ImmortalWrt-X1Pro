# 修复当前审查问题

## 目标与非目标

- 修复 X1 Pro sysupgrade TAR 内部板名与运行时板名不一致的问题。
- 恢复原设备配置需要的 USB3 驱动和自动挂载包。
- 在 GitHub Actions 发布前校验固件结构、目标设备和关键软件包。
- 在发布前验证 sysupgrade 内层 kernel/root 非空且分别为 FIT 与 SquashFS 格式。
- 验证 HomeProxy 默认 TProxy 与可选 TUN 模式的运行依赖完整，并在最终 manifest 中核对关键依赖闭包。
- 降低第三方 GitHub Action 使用可变引用和过宽令牌权限带来的风险。
- 确保交互式 tmate 会话仅允许触发者通过 GitHub SSH 公钥连接，并在缺少公钥时安全失败。
- 让 Release 与 Workflow 清理遍历完整分页结果，并将孤立 Tag 清理限制为本项目的 `X1Pro-*` Release Tag。
- 更正文档及维护工作流中与实际代码不一致的说明。
- 不改变 NAND 分区布局、U-Boot 刷写方式、HomeProxy 功能范围或依赖版本。

## 当前理解

- 镜像配置名为 `oraybox_x1-pro-ubootmod`，运行时板名为 `oray,x1pro-v1-ubootmod`；若不显式设置 `BOARD_NAME`，sysupgrade TAR 的目录名无法通过设备端校验。
- 当前 `DEVICE_PACKAGES` 未包含原设备定义中的 `kmod-usb3` 和 `automount`。
- 构建工作流目前仅按文件名选择并发布产物，没有验证 TAR 成员、metadata 或 manifest。
- 构建工作流全局授予写权限，并至少有一个第三方 Action 使用可变的 `main` 引用。
- 当前产物校验只检查 TAR 成员名称，空文件或格式错误的 kernel/root 仍可能通过。
- `gh release list` 默认只返回有限条目，Workflow 清理也只显式读取 200 条；孤立 Tag 清理目前会覆盖所有无 Release 的仓库 Tag。
- Workflow 数字输入 `retain_days=0` 经 `${{ inputs.retain_days || '7' }}` 处理后会变成 7，与“0=全部删除”的声明冲突。
- `delete-tags` 依赖可能被跳过的 `delete-releases`，但条件未显式使用状态函数；GitHub 会隐式追加 `success()`，因此默认仅清理 Tag 的手动任务无法运行。
- menuconfig 可从 Tag ref 手动触发，但保存步骤把 `GITHUB_REF_NAME` 当作分支执行 pull/push，导致失败或目标 ref 语义错误。
- Release 日期解析失败目前只跳过且仍报告成功，会隐藏不完整清理结果。
- 两个清理工作流未校验保留天数为非负整数；负数会让 GNU `date` 生成未来截止时间，从而扩大到近乎全量删除，小数也不符合既有“天/0”语义。
- Workflow run 的正保留期分支只处理 `success/failure/cancelled/skipped`，其他 GitHub 完成结论不会过期清理；失败类也漏掉 `timed_out/action_required/startup_failure`。
- 构建后的运行记录清理和依赖 Release 清理的 Tag job 使用 `always()` 时，用户取消任务后仍可能启动破坏性清理。
- 构建工作流固定的 `Mattraks/delete-workflow-runs` 会统计逐条删除失败却仍以成功结束，且默认遍历仓库所有 workflow，超出当前构建的最小清理范围。
- `unsquashfs4 -s` 只读取 SquashFS superblock，截断到只剩头部的数据仍可能通过，无法证明 rootfs 主体可解压。
- OpenWrt rootfs 含 `/dev/console` 等设备节点，普通 GitHub runner 完整解包会产生非致命 rc=2；需只忽略这类输出/权限告警，不能忽略致命损坏 rc=1。
- 固定版本 HomeProxy 的 TUN 模式调用 `ip tuntap`，但精简配置丢失旧配置已有的 `ip-full`；BusyBox `ip` 不提供该命令。
- 固定版本 HomeProxy 的资源更新脚本直接调用 `wget` 与 `jsonfilter`，ucode 脚本直接导入 `fs`、`ubus`、`uci`，防火墙脚本依赖带 JSON 支持的 `nft`；这些包当前由基础系统、LuCI 或 firewall4 间接选中，但发布门禁尚未明确验证。
- 当前 README 仍称 USB 存储与自动挂载已移除，但设备 profile 已恢复 `kmod-usb3` 与 `automount`，后者会带入存储和文件系统依赖。

## 实施计划

1. 在设备定义中设置与运行时兼容名对应的 `BOARD_NAME`，并恢复 USB 包。
2. 在构建后验证唯一 sysupgrade 产物、TAR 目录及文件、内层镜像大小与格式、固件 metadata 和 manifest 中的关键包。
3. 将第三方 Action 固定到已解析的 commit，并把权限缩小到相应 job；必要时拆分发布和清理 job。
4. 强制 tmate 使用触发者的 GitHub SSH 公钥授权，不允许无公钥会话退化为公开访问。
5. 使用 GitHub API 分页遍历 Release 与 Workflow runs，保留数值 0 的清理语义；孤立 Tag 只处理 `X1Pro-*`，不删除普通源码 Tag。
6. 补回 `ip-full`，并对 HomeProxy、sing-box、firewall4、dnsmasq-full、TProxy/TUN、LuCI HTTPS/中文、直接依赖及 HomeProxy 实际调用的关键运行时命令/ucode 模块执行配置与 manifest 双层校验。
7. 更正 U-Boot 配置路径、USB 预装说明及维护工作流注释，不改变保留期限和状态筛选语义。
8. 让孤立 Tag job 在依赖 job 被跳过时仍按输入执行；对非分支 ref 的 menuconfig 请求明确报错；把 Release 元数据解析失败计入任务失败。
9. 在读取列表或执行删除前验证两个 retention 输入仅为非负整数，拒绝负数、小数和非数值输入。
10. 让所有 completed run 在超过保留期后均可清理，并按 GitHub CLI 的失败分类覆盖 `failure/timed_out/action_required/startup_failure`；取消任务时不启动后置运行记录或 Tag 清理。
11. 用受控的分页 `gh api` 脚本替换构建后的第三方清理 Action，只清理当前构建 workflow 并保留最新 10 条 completed run；逐条失败累计后让 job 失败。
12. 在发布前把 rootfs 完整解包到 runner 临时目录，以实际读取并解压所有 SquashFS 元数据和数据块；保留 `-s` 的结构摘要用于日志。

## 验证计划

- 检查 Shell 与 YAML 语法。
- 在固定 ImmortalWrt 源码上重新应用设备补丁，并运行 `make defconfig` 可行性检查。
- 静态验证 sysupgrade 生成板名与设备端检查板名完全一致。
- 检查 Action 引用不再使用可变分支，且 job 权限符合用途。
- 检查 tmate 明确启用 `limit-access-to-actor`，且 menuconfig 仍只由手动 SSH 调试输入触发。
- 使用本地夹具覆盖正常固件、空 kernel/root、错误 FIT 和错误 SquashFS 场景。
- 使用分页 API 响应夹具验证 Release/Workflow 数据归一化及 `X1Pro-*` Tag 过滤。
- 使用工作流条件回归确认默认 `do_releases=false/do_tags=true` 仍会执行 Tag 清理，并阻止 Tag ref 启动可保存的 menuconfig。
- 使用异常日期与删除 API 失败夹具确认维护任务以非零状态结束。
- 使用 `0`、正整数、负数和小数夹具验证保留期输入边界，确认无效输入发生在任何 API 列举/删除之前。
- 使用全部已知 conclusion 值验证过期 run 均被清理、失败类即时清理且当前/未完成 run 被保留；静态验证取消条件使用 `!cancelled()`。
- 使用多页、超过 10 条、未完成/current run 和删除失败夹具验证构建后清理的范围、保留数量与失败传播。
- 使用有效 SquashFS 与截断样本验证完整解包门禁：有效镜像通过、仅有有效 superblock 的截断镜像失败。
- 对照固定 feeds 的 HomeProxy、sing-box、firewall4、iproute2 与 automount 包声明和 HomeProxy 脚本中的命令/ucode 导入，验证最终配置和 manifest 门禁覆盖实际依赖。
- 对非补丁文件运行 `git diff --check`，对设备补丁运行应用检查，并审阅最终差异。

## 风险与影响

- `BOARD_NAME` 只改变 sysupgrade TAR 内部目录和 metadata 生成上下文，不改变 DTS compatible 或 NAND 布局。
- 增加 USB 包会增大固件体积，但 112 MiB UBI 布局有足够空间，仍需通过实际构建确认。
- 发布 job 拆分可能影响 artifact 传递和构建时间变量，需要验证工作流表达式和输出。
- 产物校验会让缺包或格式异常的构建直接失败，这是预期行为。
- 全量分页会增加清理任务的 API 请求数量，但不会改变既有保留期限和运行状态筛选规则。
- 将 Tag 范围限制为 `X1Pro-*` 会保留其他无 Release 的普通 Tag，避免误删源码或维护 Tag。
- menuconfig 仅允许分支 ref；从 Tag 页面手动触发 SSH 配置会明确失败并说明原因，正常分支触发不受影响。
- 异常 Release 日期会使清理 job 失败并保留该 Release，便于维护者发现上游数据或解析异常。
- 无效保留天数现在会让维护任务明确失败；合法的 `0`（全部清理）和正整数语义保持不变。
- 正保留期会清理所有超过截止时间的 completed run；`delete_failed=YES` 仍只让失败类提前清理，`neutral/stale` 等只按年龄处理。
- 用户取消任务时将跳过后置 workflow-run/Tag 清理；依赖 job 失败或跳过但整个任务未取消时，仍按原有输入执行清理。
- 构建后即时清理从“遍历仓库全部 workflow”收窄为当前 X1 Pro 构建 workflow；全仓库历史仍由独立定时清理工作流管理。
- 完整解包会增加构建后的临时磁盘占用和少量验证时间，但不会修改固件内容；临时目录由 GitHub runner 回收。
- 完整解包使用 SquashFS 4.7.4 的 `-no-exit-code` 仅屏蔽设备节点等非致命 rc=2；截断、EOF 和数据损坏仍以 rc=1 阻止发布。
- `ip-full` 会小幅增加固件体积，但它是 HomeProxy 暴露的 TUN 模式执行 `ip tuntap` 的必要运行依赖。
- 新增的 `wget`、`jsonfilter`、ucode 与 nftables 检查只验证构建系统已经解析出的基础/间接依赖，不重复把它们写入 diffconfig，因此不会额外扩大固件包集合。

## 执行调整

- 为真正隔离第三方构建 Action 与写令牌，将发布和运行记录清理拆成独立 job，而不是只移动权限声明。
- 将交互式 tmate 与配置提交拆成两个 job，tmate 只获得源码读取权限，写入 job 只使用官方 artifact/checkout Action。
- 将 tmate 设置为仅接受触发者在 GitHub 登记的 SSH 公钥；触发者未登记公钥时让任务失败，不开放匿名会话。
- 保留现有清理触发条件、期限和状态筛选，只修复分页范围并缩小 Tag 删除目标。
- HomeProxy 使用完整 `sing-box` variant；其声明的直接依赖继续由构建系统解析，只显式补充上游未声明但 TUN 模式实际调用的 `ip-full`。
- 发布前同时检查 `make defconfig` 后的关键配置和最终 manifest，避免配置符号被静默丢弃。
- 第三方 Action 引用通过上游仓库解析后固定到 commit；官方 `download-artifact` 也固定到当前 v8 commit。
- 本机 Apple GNU Make 3.81 不满足 ImmortalWrt 要求，不能直接运行 `make defconfig` 或完整固件构建；改用一次性 Debian/glibc Docker 环境在固定源码/feeds 上完成 `make defconfig`，并在干净 clone 中验证补丁应用；完整固件编译仍未运行。
- `git diff --check` 对补丁文件内必需的 diff context 标记产生空白字符误报；不破坏补丁格式，改为排除该文件执行 whitespace 检查，并单独验证补丁可应用。
- HomeProxy 运行时闭包采用“双层”策略：diffconfig 只显式添加上游未声明的 `ip-full` 与需要 nftset 功能的 `dnsmasq-full`；`make defconfig` 及最终 manifest 额外核对上游依赖链必须带入的命令和 ucode 模块，避免复制并固化整棵传递依赖树。
- 首次依赖复核遇到临时源码里不同 libc/架构的 host-tool 缓存，以及一次性容器缺少 `wget`/distutils；隔离旧缓存并补齐仅存在于容器内的构建前置后，最终 `make defconfig` 通过。前两次环境失败不计为项目验证通过。
