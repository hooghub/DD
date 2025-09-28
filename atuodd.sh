#!/bin/bash
# 一键 DD 官方纯净系统脚本（增强版）
# 支持 Debian / Ubuntu / Alpine
# 自动检测架构 + 系统盘 + root密码 + SSH端口 + 静态网络
# 增加根盘保护提示
# Author: Chis

set -e

echo "=================== 一键 DD 系统安装（增强版） ==================="

# 检查 root
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1

# 检测架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH_NAME="amd64" ;;
  aarch64) ARCH_NAME="arm64" ;;
  *) echo "不支持的架构: $ARCH" && exit 1 ;;
esac
echo "[INFO] 检测到架构: $ARCH_NAME"

# 获取公网 IP、网关、网卡
IPV4=$(curl -s4 ifconfig.me || wget -qO- ipv4.icanhazip.com)
GATEWAY=$(ip route | grep default | awk '{print $3}')
IFACE=$(ip route | grep default | awk '{print $5}')
NETMASK="255.255.255.0"  # 可按需修改

echo "[INFO] 公网 IP: $IPV4"
echo "[INFO] 默认网关: $GATEWAY"
echo "[INFO] 网卡接口: $IFACE"

# 检测磁盘
DISKS=($(lsblk -dpno NAME | grep -E "/dev/(sd|vd|nvme)"))
if [[ ${#DISKS[@]} -eq 0 ]]; then
  echo "未检测到可用磁盘" && exit 1
elif [[ ${#DISKS[@]} -eq 1 ]]; then
  TARGET_DISK="${DISKS[0]}"
  echo "[INFO] 自动选择系统盘: $TARGET_DISK"
else
  echo "检测到多块磁盘，请选择系统盘:"
  select d in "${DISKS[@]}"; do
    TARGET_DISK="$d"
    break
  done
fi

# 检测是否选择了当前根盘
ROOT_DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
if [[ "$TARGET_DISK" == "$ROOT_DISK" ]]; then
  echo "⚠️ 你选择的磁盘是当前运行系统的根盘！"
  echo "  建议进入 VPS Rescue / ISO 模式再执行此脚本。"
  read -p "确认仍要继续覆盖根盘？(yes/no): " CONFIRM_ROOT
  [[ "$CONFIRM_ROOT" != "yes" ]] && echo "已取消操作" && exit 1
fi

# 系统菜单
echo "请选择要安装的系统（输入编号后回车）:"
echo "------------------------------------------------"
echo "  1) Debian 11 (Bullseye)"
echo "  2) Debian 12 (Bookworm)"
echo "  3) Ubuntu 20.04 (Focal LTS)"
echo "  4) Ubuntu 22.04 (Jammy LTS)"
echo "  5) Ubuntu 24.04 (Noble LTS)"
echo "  6) Alpine Linux (最新稳定版)"
echo "------------------------------------------------"
read -p "请输入编号: " OS_CHOICE

case $OS_CHOICE in
  1) OS="Debian 11"; IMG_URL="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-generic-${ARCH_NAME}.img"; TYPE="img" ;;
  2) OS="Debian 12"; IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-${ARCH_NAME}.img"; TYPE="img" ;;
  3) OS="Ubuntu 20.04"; IMG_URL="https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-${ARCH_NAME}.img"; TYPE="img" ;;
  4) OS="Ubuntu 22.04"; IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-${ARCH_NAME}.img"; TYPE="img" ;;
  5) OS="Ubuntu 24.04"; IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-${ARCH_NAME}.img"; TYPE="img" ;;
  6) OS="Alpine"; IMG_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${ARCH_NAME}/alpine-virt-latest-${ARCH_NAME}.tar.gz"; TYPE="tar" ;;
  *) echo "无效选择" && exit 1 ;;
esac

# root 密码和 SSH 端口
read -p "请输入 root 密码 (默认: root@123): " ROOT_PASS
ROOT_PASS=${ROOT_PASS:-root@123}
read -p "请输入 SSH 端口 (默认: 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

echo "------------------------------------------------"
echo "[INFO] 系统: $OS"
echo "[INFO] 镜像: $IMG_URL"
echo "[INFO] root密码: $ROOT_PASS"
echo "[INFO] SSH端口: $SSH_PORT"
echo "------------------------------------------------"

# 确认操作
echo "⚠️ 注意: 此操作会清空 $TARGET_DISK 上的所有数据！"
read -p "确认继续？(yes/no): " confirm
[[ "$confirm" != "yes" ]] && echo "已取消" && exit 1

# 下载镜像
TMP_IMG="/tmp/os.img"
wget -O $TMP_IMG $IMG_URL

# 写入系统盘
if [[ $TYPE == "img" ]]; then
  echo "[INFO] 写入 IMG 镜像到 $TARGET_DISK ..."
  dd if=$TMP_IMG of=$TARGET_DISK bs=4M status=progress oflag=direct
  sync
else
  echo "[INFO] 写入 Alpine 系统到 $TARGET_DISK ..."
  mkfs.ext4 -F $TARGET_DISK
  mount $TARGET_DISK /mnt
  tar -xzpf $TMP_IMG -C /mnt
  sync
fi

# 配置 root 密码、SSH 和网络（仅 IMG 支持 chroot）
if [[ $TYPE == "img" ]]; then
  MOUNT_DIR="/mnt/newos"
  mkdir -p $MOUNT_DIR
  mount ${TARGET_DISK}1 $MOUNT_DIR || true

  if [ -d "$MOUNT_DIR/etc" ]; then
    # root 密码
    echo "root:$ROOT_PASS" | chroot $MOUNT_DIR chpasswd
    # SSH
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' $MOUNT_DIR/etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' $MOUNT_DIR/etc/ssh/sshd_config
    echo "Port $SSH_PORT" >> $MOUNT_DIR/etc/ssh/sshd_config

    # 网络配置
    if [[ $OS == Debian* || $OS == Ubuntu* ]]; then
      if [[ -d "$MOUNT_DIR/etc/netplan" ]]; then
        cat > $MOUNT_DIR/etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  ethernets:
    $IFACE:
      addresses: [$IPV4/24]
      gateway4: $GATEWAY
      nameservers:
        addresses: [8.8.8.8,8.8.4.4]
EOF
      else
        cat > $MOUNT_DIR/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $IFACE
iface $IFACE inet static
  address $IPV4
  netmask $NETMASK
  gateway $GATEWAY
EOF
      fi
    fi
  fi

  umount $MOUNT_DIR || true
fi

echo "=================== 安装完成 ==================="
echo "系统: $OS"
echo "架构: $ARCH_NAME"
echo "IP: $IPV4"
echo "SSH端口: $SSH_PORT"
echo "root密码: $ROOT_PASS"
echo "请重启 VPS 后直接 SSH 登录"
