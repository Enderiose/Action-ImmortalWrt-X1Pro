#!/usr/bin/env python3
"""
将 WiFi 默认配置脚本注入到 ImmortalWrt sysupgrade tar 固件中。

用法:
  python3 inject_wifi_script.py <firmware.bin> <wifi_script.sh>

原理:
  固件格式: [tar 数据][padding][JSON][metadata footer]
  我们只修改 tar 部分，不碰 metadata。
"""

import os
import sys
import tarfile
import tempfile
import shutil

FW_MAGIC = b"FW"  # metadata footer 魔数


def find_metadata_offset(data: bytes) -> int:
    """找到固件文件中 metadata 块（FW 魔数）的起始位置。"""
    pos = data.rfind(FW_MAGIC)
    if pos == -1:
        raise ValueError("固件中未找到 FW metadata 魔数")
    # FW 后紧跟 version + flags，再后面是实际 metadata 数据
    # 确保找到的是真正的 metadata 开头（version='x'=120, flags='0'=48）
    if pos + 2 < len(data) and data[pos + 2:pos + 3] in (b"x", b"0", b"1"):
        print(f"  [info] metadata 起始于 offset {pos}")
        return pos
    # 往前找
    pos = data.rfind(b"\x46\x57")  # "FW" in hex
    if pos == -1:
        raise ValueError("未找到有效 FW metadata 块")
    print(f"  [info] metadata 起始于 offset {pos}")
    return pos


def extract_tar_data(fw_path: str) -> tuple[bytes, bytes]:
    """
    提取固件中的 tar 数据部分（不含 metadata 块）。
    返回 (tar_data, metadata_tail)。
    """
    with open(fw_path, "rb") as f:
        data = f.read()

    meta_start = find_metadata_offset(data)
    tar_data = data[:meta_start]
    # 处理 tar padding (512-byte aligned，末尾可能有 0)
    tail = data[meta_start:]
    return tar_data, tail


def list_tar_members(tar_data: bytes) -> list:
    """列出 tar 中的所有文件成员。"""
    members = []
    try:
        with tarfile.open(fileobj=__import__("io").BytesIO(tar_data)) as tf:
            members = tf.getnames()
    except Exception as e:
        print(f"  [warn] 无法解析 tar: {e}")
    return members


def inject_wifi_script(fw_path: str, wifi_script_path: str) -> bool:
    """
    将 WiFi 脚本注入到固件 tar 中。
    - 如果 uci-defaults/91-set-wifi-default 已存在 → 替换
    - 如果不存在 → 添加
    """
    with open(wifi_script_path, "rb") as f:
        script_data = f.read()

    script_name = os.path.basename(wifi_script_path)
    target_path = f"etc/uci-defaults/{script_name}"

    print(f"[inject] 读取固件: {fw_path}")
    tar_data, metadata_tail = extract_tar_data(fw_path)
    existing = list_tar_members(tar_data)
    print(f"  [ok] 当前固件内已有 {len(existing)} 个文件")

    # 解析现有 tar
    tf_out = __import__("io").BytesIO()
    inject_target = f"sysupgrade-oray_x1pro-v1-ubootmod/{target_path}"

    added = False
    with tarfile.open(fileobj=__import__("io").BytesIO(tar_data)) as tf_in:
        # 复制所有现有成员
        with tarfile.open(fileobj=tf_out, mode="w", format=tarfile.PAX_FORMAT) as tf_out_inner:
            # 先写所有现有成员
            for member in tf_in.getmembers():
                if member.name == inject_target:
                    # 跳过旧版本，准备替换
                    continue
                data = tf_in.extractfile(member)
                if data is not None:
                    tf_out_inner.addfile(member, data)

        # 添加/替换 wifi 脚本
        # 构建 tar header
        info = tarfile.TarInfo(name=inject_target)
        info.size = len(script_data)
        info.mode = 0o755
        info.uid = 0
        info.gid = 0
        info.uname = "root"
        info.gname = "root"
        import time
        info.mtime = int(time.time())

        tf_out_inner = __import__("io").BytesIO()
        with tarfile.open(fileobj=tf_out_inner, mode="w", format=tarfile.PAX_FORMAT) as tf_new:
            # 先写所有现有成员
            with tarfile.open(fileobj=__import__("io").BytesIO(tar_data)) as tf_in2:
                for member in tf_in2.getmembers():
                    if member.name == inject_target:
                        continue
                    data = tf_in2.extractfile(member)
                    if data is not None:
                        tf_new.addfile(member, data)
            # 添加 wifi 脚本
            tf_new.addfile(info, __import__("io").BytesIO(script_data))

        result_data = tf_out_inner.getvalue()

    # 写回固件文件（tar + padding + metadata）
    new_fw = result_data + metadata_tail

    # 保留原文件备份
    backup = fw_path + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(fw_path, backup)
        print(f"  [ok] 备份原固件为 {backup}")

    with open(fw_path, "wb") as f:
        f.write(new_fw)

    size_change = len(new_fw) - (len(tar_data) + len(metadata_tail))
    print(f"  [ok] 注入完成: +{size_change} bytes")
    print(f"  [ok] 新固件大小: {len(new_fw)} bytes ({len(new_fw)/1024/1024:.1f} MB)")

    # 验证
    with open(fw_path, "rb") as f:
        verify = f.read()
    if FW_MAGIC in verify[:verify.rfind(FW_MAGIC)]:
        print("  [ERROR] 验证失败：FW 魔数被意外移动")
        return False
    print("  [ok] 验证通过：metadata 块位置正确")
    return True


def main():
    if len(sys.argv) < 3:
        print("用法: python3 inject_wifi_script.py <firmware.bin> <wifi_script.sh>")
        sys.exit(1)

    fw_path = sys.argv[1]
    wifi_script = sys.argv[2]

    if not os.path.exists(fw_path):
        print(f"[error] 固件文件不存在: {fw_path}")
        sys.exit(1)
    if not os.path.exists(wifi_script):
        print(f"[error] WiFi 脚本不存在: {wifi_script}")
        sys.exit(1)

    ok = inject_wifi_script(fw_path, wifi_script)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
