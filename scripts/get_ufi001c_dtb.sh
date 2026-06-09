#!/bin/bash -e
#
# UFI-001C 设备树获取脚本
# 从 postmarketOS 内核包或主线内核源码获取 UFI-001C 的 dtb
#

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DTB_DST="${SCRIPT_DIR}/dtbs"

mkdir -p "$DTB_DST"

echo "============================================"
echo " UFI-001C 设备树获取"
echo "============================================"
echo ""

# 方式一: 从 postmarketOS 内核 APK 中提取（推荐）
echo "方式 1: 从 postmarketOS 内核包提取..."
PMOS_KERNEL_URL="http://mirror.postmarketos.org/postmarketos/v24.06/aarch64/linux-postmarketos-qcom-msm8916-6.6-r5.apk"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

if wget -q -O "${TMPDIR}/kernel.apk" "$PMOS_KERNEL_URL"; then
    # APK 是 tar.gz 格式
    tar xzf "${TMPDIR}/kernel.apk" -C "$TMPDIR" || true
    
    # 查找 ufi001c dtb
    DTB_FILE=$(find "$TMPDIR" -name "msm8916-thwc-ufi001c.dtb" 2>/dev/null | head -1)
    
    if [ -n "$DTB_FILE" ]; then
        cp "$DTB_FILE" "${DTB_DST}/msm8916-thwc-ufi001c.dtb"
        echo "✅ 成功获取: ${DTB_DST}/msm8916-thwc-ufi001c.dtb"
        ls -lh "${DTB_DST}/msm8916-thwc-ufi001c.dtb"
        exit 0
    else
        echo "⚠️  APK 中未找到 msm8916-thwc-ufi001c.dtb"
        echo "   使用方式 2 编译..."
    fi
else
    echo "⚠️  无法下载内核包 (网络问题)"
fi

# 方式二: 克隆主线内核源码并编译（需要 dtc）
echo ""
echo "方式 2: 从主线内核源码编译..."

KERNEL_BRANCH="wip/msm8916/7.0"

if command -v dtc &>/dev/null && command -v gcc-aarch64-linux-gnu &>/dev/null; then
    # 检查是否有 git
    if command -v git &>/dev/null; then
        KERNEL_DIR="${TMPDIR}/linux"
        git clone --depth=1 -b "$KERNEL_BRANCH" \
            https://github.com/msm8916-mainline/linux.git "$KERNEL_DIR" 2>/dev/null || {
            # 浅 clone 失败，尝试完整 clone
            git clone --depth=1 \
                https://github.com/msm8916-mainline/linux.git "$KERNEL_DIR" 2>/dev/null
        }
        
        if [ -d "$KERNEL_DIR" ]; then
            cd "$KERNEL_DIR"
            make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs 2>/dev/null || {
                # 如果完整编译失败，直接使用 dtc
                echo "   尝试仅编译 ufi001c dtb..."
                cpp -nostdinc -I include -I arch/arm64/boot/dts -undef -x assembler-with-cpp \
                    arch/arm64/boot/dts/qcom/msm8916-thwc-ufi001c.dts \
                    "${TMPDIR}/msm8916-thwc-ufi001c.dts.pre" 2>/dev/null && \
                dtc -@ -I dts -O dtb -o "${DTB_DST}/msm8916-thwc-ufi001c.dtb" \
                    "${TMPDIR}/msm8916-thwc-ufi001c.dts.pre" 2>/dev/null
            }
            
            DTB_FILE=$(find . -name "msm8916-thwc-ufi001c.dtb" 2>/dev/null | head -1)
            if [ -n "$DTB_FILE" ]; then
                cp "$DTB_FILE" "${DTB_DST}/msm8916-thwc-ufi001c.dtb"
                echo "✅ 成功编译: ${DTB_DST}/msm8916-thwc-ufi001c.dtb"
                ls -lh "${DTB_DST}/msm8916-thwc-ufi001c.dtb"
                exit 0
            fi
        fi
    fi
fi

# 方式三: 直接从主线内核仓库的 raw 链接下载预编译 dtb
echo ""
echo "方式 3: 从主线内核下载 dtb..."
# 最新主线内核 (torvalds) 已包含 msm8916-thwc-ufi001c
# 从 Linux 6.12+ 开始可用
RAW_BASE="https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom"
if curl -L -f "${RAW_BASE}/msm8916-thwc-ufi001c.dts" -o /dev/null 2>/dev/null; then
    echo "   主线内核中找到了设备树源文件"
    echo "   请在目标设备或构建环境中运行此命令编译:"
    echo "     dtc -@ -I dts -O dtb -o dtbs/msm8916-thwc-ufi001c.dtb msm8916-thwc-ufi001c.dts"
fi

echo ""
echo "============================================"
echo " 无法自动获取 DTB"
echo "============================================"
echo ""
echo "请手动获取:"
echo "  1. 在 WSL 中运行:"
echo "     git clone --depth=1 https://github.com/msm8916-mainline/linux.git"
echo "     cd linux && make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs"
echo "     find . -name 'msm8916-thwc-ufi001c.dtb' -exec cp {} /path/to/OpenStick-Builder/dtbs/ \;"
echo ""
echo "  2. 或者直接从 GitHub raw 下载源文件并编译:"
echo "     mkdir -p dtbs_tmp && cd dtbs_tmp"
echo "     curl -LO https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom/msm8916-ufi.dtsi"
echo "     curl -LO https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom/msm8916-thwc-ufi001c.dts"
echo "     dtc -@ -I dts -O dtb -o msm8916-thwc-ufi001c.dtb msm8916-thwc-ufi001c.dts"
echo "     cp msm8916-thwc-ufi001c.dtb /path/to/OpenStick-Builder/dtbs/"
