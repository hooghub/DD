#!/bin/bash
# VPS 内虚拟磁盘 DD 测试脚本
# 自动创建虚拟磁盘、下载镜像、DD 到虚拟盘并挂载
# Author: ChatGPT

set -e

echo "================= VPS 内虚拟磁盘 DD 测试 ================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 设置虚拟盘大小
read -p "请输入虚拟磁盘大小（MB，默认 2048）: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-2048}

# 创建虚拟磁盘文件
VIMG="/root/test_disk.img"
echo "[INFO] 创建虚拟磁盘文件 $VIMG 大小 ${DISK_SIZE}MB ..."
dd if=/dev/zero of=$VIMG bs=1M count=$DISK_SIZE status=progress

# 挂载为 loop 设备
LOOP_DEV=$(losetup --show -fP $VIMG)
echo "[INFO] 虚拟磁盘映射到 $LOOP_DEV"

# 系统选择菜单
echo "请选择要测试的系统镜像:"
echo "  1) Debian 12 Bookworm"
echo "  2) Ubuntu 22.04 Jammy"
echo "  3) Alpine Linux 最新稳定版"
read -p "输入编号: " OS_CHOICE

case $OS_CHOICE in
  1)
    IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.img"
    ;;
  2)
    IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    ;;
  3)
    IMG_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-virt-latest-x86_64.tar.gz"
    ;;
  *)
    echo "无效选择" && exit 1
    ;;
esac

# 下载镜像
TMP_IMG="/tmp/os.img"
echo "[INFO] 下载镜像 $IMG_URL ..."
wget -O $TMP_IMG $IMG_URL

# 格式化 loop 设备（如果是 tar 则挂载 ext4，img 则直接 DD）
if [[ $OS_CHOICE -eq 3 ]]; then
    echo "[INFO] Alpine 镜像为 tar.gz，创建 ext4 文件系统..."
    mkfs.ext4 -F $LOOP_DEV
    mount $LOOP_DEV /mnt
    echo "[INFO] 解压 Alpine 镜像到 /mnt ..."
    tar -xzpf $TMP_IMG -C /mnt
    sync
else
    echo "[INFO] 写入镜像到虚拟磁盘 $LOOP_DEV ..."
    dd if=$TMP_IMG of=$LOOP_DEV bs=4M status=progress
    sync
fi

# 挂载检查（可选）
if [[ $OS_CHOICE -ne 3 ]]; then
    mkdir -p /mnt/test_disk
    mount $LOOP_DEV /mnt/test_disk
    echo "[INFO] 镜像挂载到 /mnt/test_disk，目录结构如下:"
    ls /mnt/test_disk | head -20
fi

echo "================= 测试完成 ================="
echo "虚拟盘路径: $VIMG"
echo "挂载点: /mnt/test_disk (img) 或 /mnt (tar)"
echo "循环设备: $LOOP_DEV"

read -p "是否卸载并清理虚拟磁盘? (yes/no): " CLEAN
if [[ "$CLEAN" == "yes" ]]; then
    umount /mnt/test_disk 2>/dev/null || umount /mnt
    losetup -d $LOOP_DEV
    rm -f $VIMG $TMP_IMG
    echo "[INFO] 已清理虚拟盘"
fi

echo "[INFO] 完成"
