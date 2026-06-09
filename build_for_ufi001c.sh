#!/bin/bash -e
#
# OpenStick-Builder: 一键构建 UFI-001C Debian 系统
# 目标: UFI-001C / UFI103S (MSM8916)
# 系统: Debian Trixie (13)
#
# 使用方式:
#   sudo ./build_for_ufi001c.sh
#
# 生成镜像在 files/ 目录:
#   - gpt_both0.bin  分区表
#   - hyp.mbn        虚拟化层
#   - rpm.mbn        电源管理
#   - sbl1.mbn       二级引导
#   - tz.mbn         安全区
#   - aboot.mbn      lk2nd 引导器
#   - boot.bin       内核 + DTB + initramfs
#   - rootfs.bin     Debian 根文件系统

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "============================================"
echo " OpenStick-Builder for UFI-001C"
echo " Debian Trixie (13)"
echo "============================================"

# 检查是否为 root
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请以 root 权限运行 (sudo ./build_for_ufi001c.sh)"
    exit 1
fi

# 检查必要工具
for cmd in git wget curl debootstrap qemu-aarch64-static; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "错误: 缺少命令 '$cmd'，请先安装"
        echo "  sudo scripts/install_deps.sh"
        exit 1
    fi
done

echo ""
echo "[1/6] 安装构建依赖..."
scripts/install_deps.sh

echo ""
echo "[2/6] 构建 bootloader (hyp + lk2nd)..."
scripts/build_hyp_aboot.sh

echo ""
echo "[3/6] 提取高通固件并创建分区表..."
scripts/extract_fw.sh

echo ""
echo "[4/6] 构建 Debian rootfs (RELEASE=trixie)..."
RELEASE=trixie CHROOT="${SCRIPT_DIR}/rootfs" scripts/debootstrap.sh

echo ""
echo "[5/6] 构建 USB gadget 工具..."
scripts/build_gt.sh

echo ""
echo "[6/6] 生成最终镜像..."
scripts/build_images.sh

echo ""
echo "============================================"
echo " 构建完成!"
echo "============================================"
echo ""
echo "镜像文件在 files/ 目录:"
ls -lh files/
echo ""
echo "刷机前请准备好:"
echo "  1. EDL 9008 模式进入设备"
echo "  2. 备份原厂分区: edl r fsc fsc.bin (等7个分区)"
echo "  3. 刷写: edl w aboot files/aboot.mbn"
echo "  4. fastboot 模式刷写剩余分区"
echo ""
echo "详细步骤见项目 README.md 或 flash_ufi001c.sh"
