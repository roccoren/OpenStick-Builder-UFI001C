#!/bin/bash -e
#
# UFI-001C 刷机脚本
# 将构建好的 Debian 系统刷入设备
#
# ⚠️ 警告: 此操作会覆盖分区表，不可逆!
# ⚠️ 务必先备份原厂分区!

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FW_DIR="${SCRIPT_DIR}/files"

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请以 root 权限运行 (sudo ./flash_ufi001c.sh)"
    exit 1
fi

# 检查必要文件
REQUIRED_FILES="gpt_both0.bin hyp.mbn rpm.mbn sbl1.mbn tz.mbn aboot.mbn boot.bin rootfs.bin"
for f in $REQUIRED_FILES; do
    if [ ! -f "${FW_DIR}/${f}" ]; then
        echo "错误: 缺少文件 ${FW_DIR}/${f}"
        echo "请先运行 build_for_ufi001c.sh 构建镜像"
        exit 1
    fi
done

echo "============================================"
echo " UFI-001C 刷机脚本"
echo "============================================"
echo ""
echo "⚠️  重要提醒:"
echo "  1. 请确保已备份原厂分区!"
echo "  2. 请确保设备已进入 EDL 9008 模式!"
echo "  3. 此操作将覆盖分区表，不可逆!"
echo ""

read -p "是否继续? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "已取消"
    exit 0
fi

# 备份原厂分区
echo ""
echo "=== 步骤 1: 备份原厂分区 ==="
echo "正在通过 EDL 备份 modem 等分区..."
for n in fsc fsg modem modemst1 modemst2 persist sec; do
    echo "  备份 ${n}.bin ..."
    edl r ${n} ${n}.bin || echo "  警告: ${n} 备份失败"
done

# 刷入 aboot
echo ""
echo "=== 步骤 2: 刷入 aboot (lk2nd) ==="
edl w aboot "${FW_DIR}/aboot.mbn"

# 重启到 fastboot
echo ""
echo "=== 步骤 3: 重启到 fastboot ==="
edl e boot
edl reset
sleep 3

# 检查 fastboot 连接
echo ""
echo "=== 步骤 4: 检查 fastboot 连接 ==="
fastboot devices || { echo "错误: 设备未在 fastboot 模式"; exit 1; }

# 刷写分区
echo ""
echo "=== 步骤 5: 刷写分区表 ==="
fastboot flash partition "${FW_DIR}/gpt_both0.bin"

echo ""
echo "=== 步骤 6: 刷写 bootloader ==="
fastboot flash hyp "${FW_DIR}/hyp.mbn"
fastboot flash rpm "${FW_DIR}/rpm.mbn"
fastboot flash sbl1 "${FW_DIR}/sbl1.mbn"
fastboot flash tz "${FW_DIR}/tz.mbn"
fastboot flash aboot "${FW_DIR}/aboot.mbn"

echo ""
echo "=== 步骤 7: 刷写系统 ==="
fastboot flash boot "${FW_DIR}/boot.bin"
fastboot flash rootfs "${FW_DIR}/rootfs.bin"

# 恢复原厂分区
echo ""
echo "=== 步骤 8: 恢复原厂分区 ==="
for n in fsc fsg modem modemst1 modemst2 persist sec; do
    if [ -f "${n}.bin" ]; then
        echo "  恢复 ${n}.bin ..."
        fastboot flash ${n} ${n}.bin
    fi
done

# 重启
echo ""
echo "=== 步骤 9: 重启 ==="
fastboot reboot

echo ""
echo "============================================"
echo " 刷机完成!"
echo "============================================"
echo ""
echo "设备重启后请通过 USB 网络连接:"
echo "  SSH: ssh user@192.168.5.1  密码: 1"
echo "  WiFi: SSID=Openstick, PWD=openstick"
echo ""
echo "首次启动后执行:"
echo "  sudo sed -i 's/yiming-uz801v3/thwc-ufi001c/' /boot/extlinux/extlinux.conf"
