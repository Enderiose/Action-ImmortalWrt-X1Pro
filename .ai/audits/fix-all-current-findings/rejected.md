# 已否定发现

| ID | 原主张/指纹 | 反证 | 重新打开条件 | 状态 |
| --- | --- | --- | --- | --- |
| R-001 | patch file / diff context marker / whitespace error | `git diff --check` 把补丁文件内必需的 context 前缀空格当作源码缩进；删除前缀会破坏 unified diff | `git apply --check` 或实际应用报告 whitespace/语法错误 | rejected |
| R-002 | paired U-Boot / sysupgrade TAR `.bin` / format unsupported | 配套 multi-layout U-Boot 的 112 MiB layout 与 Linux DTS 一致，且通用 NAND TAR 写入路径处理 `kernel`/`root` | 用户设备的实际 U-Boot 版本不含该写入路径，或保存环境只允许 `fit` | rejected for paired source；真实设备状态仍 blocked |
| R-003 | repository / frontend platform audit required | 仓库仅含固件配置、脚本、工作流和文档，无可发布前端目标 | 新增 Web、Android、小程序或桌面 UI | not-applicable |
| R-004 | HomeProxy / every transitive package must be duplicated in diffconfig / otherwise incomplete | OpenWrt Kconfig 负责解析上游依赖；固定源码 `make defconfig` 已证明 24 个关键配置为 `y`，最终 manifest 另有同名门禁；把整棵依赖树写入 diffconfig 会重复固化上游实现细节 | defconfig 或最终 manifest 缺少运行时契约包，或 HomeProxy 新增未由上游依赖带入的命令/模块 | rejected；只显式补充上游未声明的 `ip-full` 与需要特性的 `dnsmasq-full` |
