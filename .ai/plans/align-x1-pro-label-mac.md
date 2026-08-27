# Align X1 Pro Label MAC

## 目标与非目标

- 目标：让 X1 Pro DTS 的标签 MAC 与 `board.d` 中的 WAN/基础 MAC 定义保持一致。
- 非目标：不修改 WAN、LAN、Wi-Fi 的实际 MAC 分配，不调整分区、升级或镜像构建逻辑。

## 当前理解

- 修改前，DTS 将 `label-mac-device` 指向 `gmac1`，其 MAC 为 Factory `0xe000` 的基础 MAC 加 1。
- 网络初始化补丁将 WAN 设置为 Factory `0xe000` 的基础 MAC，并将 `label_mac` 设置为 WAN。
- `get_mac_label()` 优先读取 DTS，因此当前 DTS 与 `/etc/board.json` 可能返回不同的标签 MAC。

## 实施计划

1. 将 X1 Pro DTS 的 `label-mac-device` 从 `gmac1` 改为 `gmac0`。
2. 保持所有 NVMEM、接口和 Wi-Fi MAC 配置不变。

## 验证计划

- 检查变更差异，确认仅修改标签 MAC 指向及本计划文件。
- 检查 DTS 中 `gmac0` 标签存在且基础 MAC 索引为 0。
- 运行仓库现有的相关静态检查或 DTS 可用性检查；若缺少完整源码构建环境则明确说明。

## 风险与影响

- `get_mac_label()` 的结果会从 LAN MAC 变为 WAN/基础 MAC。
- 依赖旧标签 MAC 作为设备唯一标识的外部系统可能将设备识别为新设备。
- 实际 WAN、LAN、Wi-Fi MAC、刷机与启动流程不受此修改影响。

## 执行调整

- 当前工作区不包含已克隆的固定版本 ImmortalWrt 源码树，且宿主机未提供 `dtc`，因此不在本地执行完整 DTS 编译；改为验证 DTS 标签引用、NVMEM 索引、补丁一致性和 Git 空白错误。完整 DTS 编译由 GitHub Actions 固件构建覆盖。
