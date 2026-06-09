# UFI-001C Debian 构建刷机指南

> 基于 OpenStick-Builder，为 UFI-001C / UFI103S (高通 MSM8916) 随身 WiFi 编译和刷入 Debian 13 (Trixie) 系统

---

## 一、环境准备

### 方案 A：WSL2（推荐 Windows 11）

```powershell
# 1. Windows PowerShell (管理员)
wsl --install -d Ubuntu-24.04
```

### 方案 B：Ubuntu 虚拟机（适合 Windows 10 或需要 USB 直通的场景）

使用 VirtualBox/VMware 安装 **Ubuntu 24.04 LTS**，并配置 **USB 直通**（用于 EDL/fastboot 刷机）。

---

## 二、安装必要依赖

在 WSL/Ubuntu 终端中执行：

```bash
# 更新并安装依赖
sudo apt update && sudo apt upgrade -y

# 安装构建工具
sudo apt install -y git wget curl python3-pip python3-dev adb fastboot \
    liblzma-dev p7zip-full cpio android-sdk-libsparse-utils \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu gcc-arm-none-eabi \
    device-tree-compiler debootstrap qemu-user-static binfmt-support \
    autoconf automake cmake libtool make pkg-config \
    unzip python3-cryptography python3-pyasn1-modules python3-pycryptodome

# 安装 EDL 工具
git clone https://github.com/bkerler/edl
cd edl
git submodule update --init --recursive
pip3 install -r requirements.txt
sudo ./autoinstall.sh
cd ..
```

---

## 三、获取设备树文件（UFI-001C）

> **为什么需要这一步？** OpenStick-Builder 的 `dtbs/` 目录默认只有 MF800 和 JZxxx 的 DTB。我们需要 UFI-001C 的设备树。

### 方法一（推荐）：从主线内核下载

```bash
cd OpenStick-Builder

# 下载设备树源文件
curl -LO https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom/msm8916-ufi.dtsi
curl -LO https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom/msm8916-thwc-ufi001c.dts
# 也下载 pm8916 公共 dtsi
curl -LO https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom/msm8916-pm8916.dtsi

# 编译 DTB
dtc -@ -I dts -O dtb -o dtbs/msm8916-thwc-ufi001c.dtb msm8916-thwc-ufi001c.dts

# 清理临时源文件
rm -f msm8916-ufi.dtsi msm8916-thwc-ufi001c.dts msm8916-pm8916.dtsi

ls -lh dtbs/msm8916-thwc-ufi001c.dtb
```

### 方法二：从内核源码编译

```bash
git clone --depth=1 https://github.com/msm8916-mainline/linux.git
cd linux
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- dtbs
find . -name "msm8916-thwc-ufi001c.dtb" -exec cp {} ../OpenStick-Builder/dtbs/ \;
cd ..
```

---

## 四、一键构建 Debian 系统

> 构建过程约需 **30-60 分钟**（取决于网络速度），建议处于良好网络环境。

```bash
cd OpenStick-Builder

# 一键构建（内部已更改 extlinux.conf 指向 ufi001c dtb）
sudo ./build_for_ufi001c.sh
```

### 如果分步执行：

```bash
cd OpenStick-Builder

# 1. 安装依赖
sudo scripts/install_deps.sh

# 2. 构建 bootloader
sudo scripts/build_hyp_aboot.sh

# 3. 提取高通固件
sudo scripts/extract_fw.sh

# 4. 构建 rootfs（Debian Trixie）
sudo RELEASE=trixie scripts/debootstrap.sh

# 5. 构建 gadget 工具
sudo scripts/build_gt.sh

# 6. 生成镜像
sudo scripts/build_images.sh
```

### 构建成功后，`files/` 目录包含：

| 文件 | 大小 | 说明 |
|------|------|------|
| `gpt_both0.bin` | 8KB | GPT 分区表 |
| `hyp.mbn` | ~64KB | 虚拟化层 |
| `rpm.mbn` | ~212KB | 电源管理固件 |
| `sbl1.mbn` | ~104KB | 二级引导器 |
| `tz.mbn` | ~196KB | TrustZone |
| `aboot.mbn` | ~408KB | lk2nd 引导加载器 |
| `boot.bin` | ~64MB | 内核 + DTB + initramfs (sparse) |
| `rootfs.bin` | ~1.5GB | Debian 根文件系统 (sparse) |

---

## 五、刷机操作

### 5.1 准备工作

1. **停止 ModemManager**（避免 EDL 端口冲突）：
   ```bash
   sudo systemctl stop ModemManager
   sudo systemctl disable ModemManager
   ```

2. **将设备进入 EDL 9008 模式**：
   - 按住设备上的复位针孔按钮
   - 同时插入 USB 数据线连接电脑
   - 确认：`lsusb` 显示 `Qualcomm HS-USB QDLoader 9008`

3. **WSL USB 直通**（如果使用 WSL）：
   ```powershell
   # Windows PowerShell (管理员)
   winget install usbipd
   usbipd list                        # 找到 Qualcomm 9008 的 BUSID
   usbipd bind --busid <BUSID>        # 绑定
   usbipd attach --wsl --busid <BUSID> # 挂载到 WSL
   ```

### 5.2 备份原厂分区（⚠️ 必须！）

```bash
cd OpenStick-Builder

for n in fsc fsg modem modemst1 modemst2 persist sec; do
    echo "备份 $n ..."
    edl r ${n} ${n}.bin
done

echo "备份完成！请妥善保存这些文件。"
```

> 这些分区包含 IMEI、MAC 地址、Modem 校准数据，**每台设备唯一**。

### 5.3 刷写系统

```bash
# 方式一：使用一键刷机脚本
sudo ./flash_ufi001c.sh

# 方式二：分步手动执行
# 1. 刷入 aboot
edl w aboot files/aboot.mbn

# 2. 重启到 fastboot
edl e boot
edl reset

# 3. 等待设备进入 fastboot 模式
sleep 3
fastboot devices

# 4. 刷写分区表
fastboot flash partition files/gpt_both0.bin
fastboot flash hyp files/hyp.mbn
fastboot flash rpm files/rpm.mbn
fastboot flash sbl1 files/sbl1.mbn
fastboot flash tz files/tz.mbn
fastboot flash aboot files/aboot.mbn

# 5. 刷写系统
fastboot flash boot files/boot.bin
fastboot flash rootfs files/rootfs.bin

# 6. 恢复原厂分区
for n in fsc fsg modem modemst1 modemst2 persist sec; do
    if [ -f "${n}.bin" ]; then
        fastboot flash ${n} ${n}.bin
    fi
done

# 7. 重启
fastboot reboot
```

---

## 六、首次启动与配置

### 6.1 连接设备

| 方式 | 参数 |
|------|------|
| **USB 网线** | `ssh user@192.168.5.1`，密码 `1` |
| **WiFi 热点** | SSID: `Openstick`，密码: `openstick` |

### 6.2 配置设备树（⚠️ 重要）

```bash
# 登录设备后执行
sudo sed -i 's/yiming-uz801v3/thwc-ufi001c/' /boot/extlinux/extlinux.conf
```

### 6.3 扩展 rootfs 分区

```bash
sudo resize2fs /dev/disk/by-partlabel/rootfs
```

### 6.4 配置 LED（可选）

```bash
# 设置蓝灯常亮
echo 0 > /sys/class/leds/red:power/brightness
echo 1 > /sys/class/leds/blue:wan/brightness
```

### 6.5 验证系统

```bash
uname -a
cat /etc/os-release
lsusb
ip link show
mmcli -m 0  # 检查基带状态
```

---

## 七、自定义设置

### 7.1 自定义预装软件包

编辑 `scripts/setup.sh`，在 `apt install` 行添加或删除软件包。

### 7.2 升级内核

```bash
wget -O - http://mirror.postmarketos.org/postmarketos/v24.06/aarch64/linux-postmarketos-qcom-msm8916-6.6-r5.apk \
    | tar xkzf - -C / --exclude=.PKGINFO --exclude=.SIGN* 2>/dev/null
```

### 7.3 Windows 环境刷机

如果不想在 WSL 中刷机，可以在 Windows 下：
1. 下载 [platform-tools](https://developer.android.com/studio/releases/platform-tools) (含 fastboot)
2. 安装 [EDL for Windows](https://github.com/bkerler/edl)
3. 双击执行 `flash_ufi001c.bat`

---

## 八、硬件引脚定义

| 引脚 | 功能 | GPIO |
|------|------|------|
| 串口 TX | UART 发送 | BLSP UART2 |
| 串口 RX | UART 接收 | BLSP UART2 |
| 复位按钮 | 重启 | GPIO 37 |
| LED 蓝 | WAN 指示灯 | GPIO 20 |
| LED 绿 | WLAN 指示灯 | GPIO 21 |
| LED 红 | 电源指示灯 | GPIO 22 |
| SIM 选择 | 外部 SIM 选择 | GPIO 0-3 |

---

## 九、故障排查

| 问题 | 原因 | 解决 |
|------|------|------|
| EDL 无法连接 | ModemManager 占用端口 | `sudo systemctl stop ModemManager` |
| fastboot 设备未找到 | 驱动问题 | Windows 下更新驱动为 `Android Bootloader Interface` |
| 系统无法启动 | 设备树不匹配 | 确认 `/boot/extlinux/extlinux.conf` 使用 `thwc-ufi001c` |
| LED 不亮 | 设备树错误 | 检查设备树文件是否正确 |
| Modem 不工作 | 缺少 modem 分区 | 重新刷入备份的 modem.bin |
| rootfs 空间不足 | 未扩展分区 | `resize2fs /dev/disk/by-partlabel/rootfs` |
| 无法进入 EDL | 需要短接 | 使用镊子短接主板上的 EDL 触点再插 USB |

---

## 十、参考资料

| 资源 | 链接 |
|------|------|
| OpenStick-Builder | https://github.com/kinsamanka/OpenStick-Builder |
| OpenStick 项目 | https://github.com/OpenStick/OpenStick |
| msm8916-mainline 内核 | https://github.com/msm8916-mainline/linux |
| pmaports 设备包 | https://gitlab.postmarketos.org/postmarketOS/pmaports |
| EDL 工具 | https://github.com/bkerler/edl |
| UFI001C 折腾记录 | https://ihexon.github.io/posts/ufimakefun/ |
| OpenStick 文档 | https://www.kancloud.cn/handsomehacker/openstick/2637559 |
| usbipd-win (WSL USB) | https://github.com/dorssel/usbipd-win |
