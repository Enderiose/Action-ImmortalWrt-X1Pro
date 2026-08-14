#!/usr/bin/env python3
"""
将 WiFi 默认配置脚本注入到 ImmortalWrt sysupgrade tar 固件中。
原理：固件 = [tar 数据][padding][metadata]。只修改 tar 部分，不碰 metadata 块。
"""

import io
import os
import sys
import tarfile
import time


FW_MAGIC = b"FW"  # metadata footer 魔数，位于 tar 数据之后


def find_metadata_pos(data: bytes) -> int:
    """找到固件中 FW metadata 块起始位置（倒序找最后一个 FW）。"""
    pos = data.rfind(FW_MAGIC)
    if pos == -1:
        raise ValueError("未找到 FW metadata 魔数")
    print(f"  [info] metadata 起始 offset: {pos}")
    return pos


def read_file(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def inject_into_tar(tar_data: bytes, inject_target: str, file_data: bytes, file_mode=0o755) -> bytes:
    """
    将文件注入 tar，返回新的 tar bytes。
    inject_target: 相对于 sysupgrade-<board>/ 的路径，如 "etc/uci-defaults/91-set-wifi-default"
    """
    result = io.BytesIO()

    with tarfile.open(fileobj=io.BytesIO(tar_data), mode="r") as tf_in:
        replaced = False
        with tarfile.open(fileobj=result, mode="w", format=tarfile.PAX_FORMAT) as tf_out:
            for member in tf_in.getmembers():
                if member.name == inject_target:
                    # 跳过旧版本
                    continue
                data = tf_in.extractfile(member)
                if data is not None:
                    tf_out.addfile(member, data)

            # 添加/替换新文件
            info = tarfile.TarInfo(name=inject_target)
            info.size = len(file_data)
            info.mode = file_mode
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            info.mtime = int(time.time())
            tf_out.addfile(info, io.BytesIO(file_data))
            replaced = True

    return result.getvalue()


def inject_wifi_script(fw_path: str, wifi_script_path: str) -> bool:
    """将 WiFi 脚本注入固件 tar 包。"""
    script_name = os.path.basename(wifi_script_path)
    # 注意：board name 在 tar 顶层的目录名中
    board_prefix = "sysupgrade-oray_x1pro-v1-ubootmod"
    inject_target = f"{board_prefix}/etc/uci-defaults/{script_name}"

    print(f"[inject] 固件: {fw_path}")
    print(f"[inject] 脚本: {wifi_script_path}")
    print(f"[inject] 目标: {inject_target}")

    fw_bytes = read_file(fw_path)
    meta_pos = find_metadata_pos(fw_bytes)
    tar_data = fw_bytes[:meta_pos]
    metadata_tail = fw_bytes[meta_pos:]

    # 检查当前固件内容
    with tarfile.open(fileobj=io.BytesIO(tar_data), mode="r") as tf:
        names = tf.getnames()
    print(f"  [ok] 现有 tar 条目: {len(names)} 个")

    if inject_target in names:
        print(f"  [info] 替换已有: {inject_target}")
    else:
        print(f"  [info] 新增条目: {inject_target}")

    script_bytes = read_file(wifi_script_path)
    new_tar = inject_into_tar(tar_data, inject_target, script_bytes, file_mode=0o755)

    new_fw = new_tar + metadata_tail

    # 备份原文件
    backup = fw_path + ".bak"
    if not os.path.exists(backup):
        with open(backup, "wb") as f:
            f.write(fw_bytes)
        print(f"  [ok] 备份: {backup}")

    with open(fw_path, "wb") as f:
        f.write(new_fw)

    print(f"  [ok] 完成: {len(new_fw)} bytes ({len(new_fw)/1024/1024:.2f} MB)")
    print(f"  [ok] 大小变化: {len(new_fw) - len(fw_bytes):+d} bytes")

    # 验证：WiFi 脚本是否在 tar 内 + metadata 是否完整
    import io as _io
    with tarfile.open(fileobj=_io.BytesIO(new_fw[:new_fw.rfind(b"FW")]), mode="r") as tf:
        names = tf.getnames()
    if inject_target in names:
        print(f"  [ok] 验证通过: {inject_target} 已存在于 tar")
        return True
    else:
        print(f"  [ERROR] 验证失败: {inject_target} 不在 tar 中")
        return False


def main():
    if len(sys.argv) < 3:
        print("用法: python3 inject_wifi_script.py <固件.bin> <WiFi脚本.sh>")
        sys.exit(1)
    fw_path = sys.argv[1]
    script_path = sys.argv[2]
    if not os.path.exists(fw_path):
        print(f"[ERROR] 固件不存在: {fw_path}")
        sys.exit(1)
    if not os.path.exists(script_path):
        print(f"[ERROR] WiFi 脚本不存在: {script_path}")
        sys.exit(1)

    ok = inject_wifi_script(fw_path, script_path)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
