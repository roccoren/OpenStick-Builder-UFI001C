#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
ROOTFS="$OUT_DIR/rootfs"
DOWNLOADS="$OUT_DIR/downloads"
ARTIFACTS="$OUT_DIR/artifacts"
STAGING="$OUT_DIR/staging"
APTROOT="$OUT_DIR/apt-sandbox"
LOGS="$OUT_DIR/logs"
LEGACY_DIR="$DOWNLOADS/legacy-openstick"
KERNEL_URL="${KERNEL_URL:-https://mirror.postmarketos.org/postmarketos/v25.06/aarch64/linux-postmarketos-qcom-msm8916-6.12.1-r2.apk}"
LEGACY_BASE_URL="${LEGACY_BASE_URL:-https://github.com/OpenStick/OpenStick/releases/download/v1/base.zip}"
LEGACY_FW_URL="${LEGACY_FW_URL:-https://github.com/OpenStick/OpenStick/releases/download/v1/firmware-ufi001c.zip}"
IMAGE_STAMP="${IMAGE_STAMP:-$(date -u +%Y%m%d)}"
IMAGE_NAME="${IMAGE_NAME:-ufi001c-debian13-hybrid-slim-$IMAGE_STAMP}"
PKGDIR="$ARTIFACTS/$IMAGE_NAME"
BOOT_PARTUUID="80780B1D-0FE1-27D3-23E4-9244E62F8C46"
ROOT_PARTUUID="A7AB80E8-E9D1-E8CD-F157-93F69B1D141E"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-1}"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
run() { log "$*"; "$@"; }
chroot_qemu() { sudo chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash -lc "$*"; }

require_tools() {
  for cmd in sudo debootstrap wget unzip tar python3 fakeroot mkfs.ext2 mkfs.ext4 sha256sum; do
    command -v "$cmd" >/dev/null || { echo "missing tool: $cmd"; exit 1; }
  done
  [ -x /usr/bin/qemu-aarch64-static ] || { echo "missing /usr/bin/qemu-aarch64-static"; exit 1; }
}

prepare_dirs() {
  rm -rf "$OUT_DIR"
  mkdir -p "$ROOTFS" "$DOWNLOADS" "$ARTIFACTS" "$STAGING" "$APTROOT" "$LOGS"
}

fetch_assets() {
  mkdir -p "$LEGACY_DIR"
  run wget -O "$DOWNLOADS/kernel.apk" "$KERNEL_URL"
  run wget -O "$LEGACY_DIR/base.zip" "$LEGACY_BASE_URL"
  run wget -O "$LEGACY_DIR/firmware-ufi001c.zip" "$LEGACY_FW_URL"
  rm -rf "$LEGACY_DIR/base" "$LEGACY_DIR/firmware-ufi001c"
  run unzip -o "$LEGACY_DIR/base.zip" -d "$LEGACY_DIR"
  run unzip -o "$LEGACY_DIR/firmware-ufi001c.zip" -d "$LEGACY_DIR"
}

bootstrap_rootfs() {
  run sudo debootstrap \
    --no-check-gpg \
    --foreign \
    --arch=arm64 \
    --variant=minbase \
    --components=main,contrib,non-free-firmware \
    trixie "$ROOTFS" https://deb.debian.org/debian

  run sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
  run sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

  cat > "$OUT_DIR/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
  chmod 755 "$OUT_DIR/policy-rc.d"
  run sudo cp "$OUT_DIR/policy-rc.d" "$ROOTFS/usr/sbin/policy-rc.d"

  cat > "$OUT_DIR/sources.list" <<'EOF'
deb https://deb.debian.org/debian trixie main contrib non-free-firmware
deb https://deb.debian.org/debian-security trixie-security main contrib non-free-firmware
deb https://deb.debian.org/debian trixie-updates main contrib non-free-firmware
EOF
  run sudo cp "$OUT_DIR/sources.list" "$ROOTFS/etc/apt/sources.list"

  run sudo chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /debootstrap/debootstrap --second-stage

  cat > "$OUT_DIR/99ufi-slim" <<'EOF'
APT::Install-Recommends "0";
APT::Install-Suggests "0";
Acquire::Languages "none";
Acquire::Retries "2";
EOF
  run sudo cp "$OUT_DIR/99ufi-slim" "$ROOTFS/etc/apt/apt.conf.d/99ufi-slim"

  run chroot_qemu "apt-get update"
  run chroot_qemu "apt-get install -y --no-install-recommends systemd systemd-sysv systemd-timesyncd dbus dbus-user-session openssh-server sudo curl locales ca-certificates network-manager modemmanager qrtr-tools rmtfs dnsmasq hostapd wpasupplicant bridge-utils iptables nftables iputils-ping net-tools procps kmod iw wireless-regdb wireguard-tools e2fsprogs nano less usbutils"
}

configure_rootfs() {
  log "Configure base system"
  echo 'openstick-debian' | sudo tee "$ROOTFS/etc/hostname" >/dev/null
  sudo tee "$ROOTFS/etc/hosts" >/dev/null <<'EOF'
127.0.0.1 localhost
127.0.1.1 openstick-debian
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
  sudo tee "$ROOTFS/etc/fstab" >/dev/null <<EOF
PARTUUID=${ROOT_PARTUUID} / ext4 defaults,noatime 0 1
PARTUUID=${BOOT_PARTUUID} /boot ext2 defaults,noatime 0 2
EOF
  sudo tee "$ROOTFS/etc/default/locale" >/dev/null <<'EOF'
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF
  echo 'Etc/UTC' | sudo tee "$ROOTFS/etc/timezone" >/dev/null
  run sudo ln -snf /usr/share/zoneinfo/Etc/UTC "$ROOTFS/etc/localtime"
  : | sudo tee "$ROOTFS/etc/machine-id" >/dev/null

  sudo mkdir -p "$ROOTFS/etc/systemd/journald.conf.d"
  sudo tee "$ROOTFS/etc/systemd/journald.conf.d/10-ufi-slim.conf" >/dev/null <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
SystemMaxUse=16M
Compress=yes
EOF

  run sudo tar xkzf "$DOWNLOADS/kernel.apk" -C "$ROOTFS" --exclude=.PKGINFO --exclude=.SIGN* --exclude=.INSTALL
  mkdir -p "$ROOTFS/boot/extlinux"
  sudo tee "$ROOTFS/boot/extlinux/extlinux.conf" >/dev/null <<EOF
linux /vmlinuz
fdt /dtbs/qcom/msm8916-thwc-ufi001c.dtb
append earlycon root=PARTUUID=${ROOT_PARTUUID,,} console=ttyMSM0,115200 no_framebuffer=true rw rootwait
EOF

  mkdir -p "$ROOTFS/lib/firmware/msm-firmware-loader"
  run sudo cp -a "$LEGACY_DIR/firmware-ufi001c/." "$ROOTFS/lib/firmware/"

  run chroot_qemu "id -u user >/dev/null 2>&1 || useradd -m -s /bin/bash user"
  run chroot_qemu "echo 'user:${DEFAULT_PASSWORD}' | chpasswd"
  run chroot_qemu "usermod -aG sudo user"
  run chroot_qemu "passwd -l root || true"
  run sudo install -m 440 /dev/null "$ROOTFS/etc/sudoers.d/user"
  echo 'user ALL=(ALL:ALL) NOPASSWD: ALL' | sudo tee "$ROOTFS/etc/sudoers.d/user" >/dev/null

  mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
  sudo tee "$ROOTFS/etc/ssh/sshd_config.d/50-openstick.conf" >/dev/null <<'EOF'
PasswordAuthentication yes
PermitRootLogin no
UsePAM yes
EOF

  sudo mkdir -p "$ROOTFS/etc/NetworkManager/conf.d" "$ROOTFS/etc/NetworkManager/system-connections" "$ROOTFS/etc/udev/rules.d"
  sudo tee "$ROOTFS/etc/NetworkManager/conf.d/10-dnsmasq.conf" >/dev/null <<'EOF'
[main]
dns=dnsmasq
EOF
  sudo python3 - <<PY
from pathlib import Path
root = Path('$ROOTFS')
repo = Path('$REPO_ROOT')
profiles = {
    'hotspot.nmconnection': {'autoconnect': 'true', 'autoconnect-priority': '100'},
    'usb.nmconnection': {'autoconnect': 'true', 'autoconnect-priority': '90'},
    'lte.nmconnection': {'autoconnect': 'true', 'autoconnect-priority': '10'},
}
for name, extra in profiles.items():
    src = repo / 'configs' / name
    data = src.read_text().splitlines()
    out = []
    in_conn = False
    inserted = False
    for line in data:
        out.append(line)
        if line.strip() == '[connection]':
            in_conn = True
            continue
        if in_conn and line.startswith('id=') and not inserted:
            for k, v in extra.items():
                out.append(f'{k}={v}')
            inserted = True
        if in_conn and line.startswith('[') and line.strip() != '[connection]':
            in_conn = False
    if in_conn and not inserted:
        for k, v in extra.items():
            out.append(f'{k}={v}')
    dst = root / 'etc/NetworkManager/system-connections' / name
    dst.write_text('\n'.join(out) + '\n')
    dst.chmod(0o600)
PY
  sudo tee "$ROOTFS/etc/udev/rules.d/99-nm-usb0.rules" >/dev/null <<'EOF'
SUBSYSTEM=="net", ACTION=="add|change|move", ENV{DEVTYPE}=="gadget", ENV{NM_UNMANAGED}="0"
EOF

  sudo mkdir -p "$ROOTFS/usr/local/sbin" "$ROOTFS/etc/systemd/system/serial-getty@ttyMSM0.service.d"
  run sudo cp "$REPO_ROOT/scripts/msm-firmware-loader.sh" "$ROOTFS/usr/local/sbin/msm-firmware-loader.sh"
  run chroot_qemu "systemd-sysusers || true; systemd-tmpfiles --create || true"
  run sudo chmod 755 "$ROOTFS/usr/local/sbin/msm-firmware-loader.sh"
  sudo tee "$ROOTFS/etc/systemd/system/msm-firmware-loader.service" >/dev/null <<'EOF'
[Unit]
DefaultDependencies=no
Before=qrtr-ns.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/msm-firmware-loader.sh
RequiresMountsFor=/lib/firmware /usr/local/sbin

[Install]
WantedBy=multi-user.target
EOF
  run sudo cp "$REPO_ROOT/configs/system/serial-getty@ttyMSM0.service.d/override.conf" "$ROOTFS/etc/systemd/system/serial-getty@ttyMSM0.service.d/override.conf"

  sudo tee "$ROOTFS/usr/local/sbin/ufi-usb-gadget.sh" >/dev/null <<'EOF'
#!/bin/sh
set -e
G=/sys/kernel/config/usb_gadget/rndis
UDC=$(ls /sys/class/udc | head -n1)
HOST_MAC=02:1a:11:00:00:01
DEV_MAC=02:1a:11:00:00:02
start_gadget() {
  [ -n "$UDC" ] || exit 0
  [ -d "$G" ] && exit 0
  mkdir -p "$G"
  echo 0x0525 > "$G/idVendor"
  echo 0xa4a2 > "$G/idProduct"
  echo 0x0100 > "$G/bcdDevice"
  echo 0x0200 > "$G/bcdUSB"
  mkdir -p "$G/strings/0x409"
  echo OpenStick > "$G/strings/0x409/manufacturer"
  echo UFI001C-Debian13 > "$G/strings/0x409/product"
  cat /etc/machine-id 2>/dev/null | head -c 12 > "$G/strings/0x409/serialnumber" || echo UFI001C > "$G/strings/0x409/serialnumber"
  mkdir -p "$G/configs/c.1/strings/0x409"
  echo RNDIS > "$G/configs/c.1/strings/0x409/configuration"
  echo 250 > "$G/configs/c.1/MaxPower"
  mkdir -p "$G/functions/rndis.usb0"
  echo "$HOST_MAC" > "$G/functions/rndis.usb0/host_addr"
  echo "$DEV_MAC" > "$G/functions/rndis.usb0/dev_addr"
  mkdir -p "$G/os_desc"
  echo 1 > "$G/os_desc/use"
  echo 0xcd > "$G/os_desc/b_vendor_code"
  echo MSFT100 > "$G/os_desc/qw_sign"
  echo RNDIS > "$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"
  echo 5162001 > "$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id"
  ln -sf "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0"
  ln -sf "$G/configs/c.1" "$G/os_desc/c.1"
  echo "$UDC" > "$G/UDC"
}
stop_gadget() {
  [ -d "$G" ] || exit 0
  echo '' > "$G/UDC" 2>/dev/null || true
  rm -f "$G/os_desc/c.1" "$G/configs/c.1/rndis.usb0" 2>/dev/null || true
  rmdir "$G/functions/rndis.usb0/os_desc/interface.rndis" 2>/dev/null || true
  rmdir "$G/functions/rndis.usb0/os_desc" 2>/dev/null || true
  rmdir "$G/functions/rndis.usb0" 2>/dev/null || true
  rmdir "$G/configs/c.1/strings/0x409" "$G/configs/c.1" 2>/dev/null || true
  rmdir "$G/strings/0x409" "$G/os_desc" 2>/dev/null || true
  rmdir "$G" 2>/dev/null || true
}
case "${1:-start}" in
  start) start_gadget ;;
  stop) stop_gadget ;;
  restart) stop_gadget; start_gadget ;;
  *) echo "usage: $0 {start|stop|restart}"; exit 2 ;;
esac
EOF
  run sudo chmod 755 "$ROOTFS/usr/local/sbin/ufi-usb-gadget.sh"
  sudo tee "$ROOTFS/etc/systemd/system/usb-gadget.service" >/dev/null <<'EOF'
[Unit]
Description=Load USB RNDIS gadget
Requires=sys-kernel-config.mount
After=sys-kernel-config.mount systemd-modules-load.service
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/sbin/modprobe libcomposite
ExecStart=/usr/local/sbin/ufi-usb-gadget.sh start
ExecStop=/usr/local/sbin/ufi-usb-gadget.sh stop

[Install]
WantedBy=multi-user.target
EOF

  sudo tee "$ROOTFS/usr/local/sbin/ufi-zram.sh" >/dev/null <<'EOF'
#!/bin/sh
set -e
[ -e /dev/zram0 ] || modprobe zram num_devices=1
SIZE_MB=256
if [ -r /proc/meminfo ]; then
  MEM_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
  MEM_MB=$((MEM_KB / 1024))
  [ "$MEM_MB" -lt 700 ] && SIZE_MB=192
fi
echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo $((SIZE_MB * 1024 * 1024)) > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
EOF
  run sudo chmod 755 "$ROOTFS/usr/local/sbin/ufi-zram.sh"
  sudo tee "$ROOTFS/etc/systemd/system/ufi-zram.service" >/dev/null <<'EOF'
[Unit]
Description=Setup zram swap for low-memory UFI001C
DefaultDependencies=no
After=systemd-modules-load.service
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ufi-zram.sh

[Install]
WantedBy=swap.target
EOF

  sudo tee "$ROOTFS/usr/local/sbin/ufi-resize-rootfs.sh" >/dev/null <<'EOF'
#!/bin/sh
set -e
MARKER=/var/lib/ufi-rootfs-resized
[ -e "$MARKER" ] && exit 0
mkdir -p /var/lib
resize2fs /dev/disk/by-partlabel/rootfs || true
touch "$MARKER"
EOF
  run sudo chmod 755 "$ROOTFS/usr/local/sbin/ufi-resize-rootfs.sh"
  sudo tee "$ROOTFS/etc/systemd/system/ufi-resize-rootfs.service" >/dev/null <<'EOF'
[Unit]
Description=Expand rootfs filesystem on first boot
After=local-fs.target
Before=multi-user.target
ConditionPathExists=!/var/lib/ufi-rootfs-resized

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ufi-resize-rootfs.sh

[Install]
WantedBy=multi-user.target
EOF

  sudo tee "$ROOTFS/usr/local/sbin/ufi-firstboot.sh" >/dev/null <<'EOF'
#!/bin/sh
set -eu
MARKER=/etc/ufi-firstboot.done
[ -e "$MARKER" ] && exit 0
systemd-sysusers || true
systemd-tmpfiles --create || true
ssh-keygen -A || true
touch "$MARKER"
EOF
  run sudo chmod 755 "$ROOTFS/usr/local/sbin/ufi-firstboot.sh"
  sudo tee "$ROOTFS/etc/systemd/system/ufi-firstboot.service" >/dev/null <<'EOF'
[Unit]
Description=UFI001C first-boot finishing tasks
ConditionPathExists=!/etc/ufi-firstboot.done
After=systemd-sysusers.service local-fs.target
Before=NetworkManager.service ModemManager.service ssh.service multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ufi-firstboot.sh
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF
}

enable_units() {
  log "Enable systemd units"
  sudo mkdir -p \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants" \
    "$ROOTFS/etc/systemd/system/getty.target.wants" \
    "$ROOTFS/etc/systemd/system/sockets.target.wants" \
    "$ROOTFS/etc/systemd/system/swap.target.wants"
  run sudo ln -snf /usr/lib/systemd/system/multi-user.target "$ROOTFS/etc/systemd/system/default.target"
  run sudo ln -snf /usr/lib/systemd/system/dbus.socket "$ROOTFS/etc/systemd/system/sockets.target.wants/dbus.socket"
  run sudo ln -snf /usr/lib/systemd/system/serial-getty@.service "$ROOTFS/etc/systemd/system/getty.target.wants/serial-getty@ttyMSM0.service"
  for unit in \
    NetworkManager.service \
    ModemManager.service \
    ssh.service \
    systemd-timesyncd.service; do
    run sudo ln -snf "/usr/lib/systemd/system/$unit" "$ROOTFS/etc/systemd/system/multi-user.target.wants/$unit"
  done
  for unit in \
    msm-firmware-loader.service \
    usb-gadget.service \
    ufi-resize-rootfs.service \
    ufi-firstboot.service; do
    run sudo ln -snf "/etc/systemd/system/$unit" "$ROOTFS/etc/systemd/system/multi-user.target.wants/$unit"
  done
  run sudo ln -snf /etc/systemd/system/ufi-zram.service "$ROOTFS/etc/systemd/system/swap.target.wants/ufi-zram.service"

  log "Disable noisy maintenance timers"
  for unit in apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer e2scrub_all.timer; do
    run sudo ln -snf /dev/null "$ROOTFS/etc/systemd/system/$unit"
  done
}

prune_rootfs() {
  log "Prune rootfs for a smaller image"
  run sudo rm -f "$ROOTFS/usr/sbin/policy-rc.d"
  run chroot_qemu "apt-get clean || true"
  run sudo rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
  run sudo rm -rf \
    "$ROOTFS/debootstrap" \
    "$ROOTFS/usr/share/doc"/* \
    "$ROOTFS/usr/share/man"/* \
    "$ROOTFS/usr/share/info"/* \
    "$ROOTFS/usr/share/lintian" \
    "$ROOTFS/var/lib/apt/lists"/* \
    "$ROOTFS/var/cache/man"/*
  if [ -d "$ROOTFS/usr/share/locale" ]; then
    find "$ROOTFS/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name 'C' ! -name 'C.UTF-8' ! -name 'en' ! -name 'en_US' -exec sudo rm -rf {} + || true
  fi
  run sudo chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"
  run sudo chmod 700 "$ROOTFS/root"
}

create_artifacts() {
  log "Create flashable image bundle"
  local bootstage="$STAGING/boot"
  local rootstage="$STAGING/rootfs"
  local bootraw="$STAGING/boot.img"
  local rootraw="$STAGING/rootfs.img"
  local bootsparse="$PKGDIR/boot.bin"
  local rootsparse="$PKGDIR/rootfs.bin"
  local zipfile="$ARTIFACTS/$IMAGE_NAME.zip"

  rm -rf "$PKGDIR" "$STAGING"
  mkdir -p "$PKGDIR" "$bootstage" "$rootstage"

  sudo tar -C "$ROOTFS/boot" -cpf - . | tar -C "$bootstage" -xpf -
  sudo tar -C "$ROOTFS" -cpf - \
    --exclude='./boot/*' \
    --exclude='./dev/*' \
    --exclude='./proc/*' \
    --exclude='./sys/*' \
    --exclude='./run/*' \
    --exclude='./tmp/*' \
    . | tar -C "$rootstage" -xpf -
  mkdir -p "$rootstage/boot" "$rootstage/dev" "$rootstage/proc" "$rootstage/sys" "$rootstage/run" "$rootstage/tmp"
  chmod 1777 "$rootstage/tmp" "$rootstage/var/tmp"

  export bootstage rootstage bootraw rootraw
  fakeroot bash -c '
    set -e
    chown -hR 0:0 "$bootstage" "$rootstage"
    chown -hR 1000:1000 "$rootstage/home/user"
    mkfs.ext2 -F -b 1024 -L boot -m 0 -d "$bootstage" "$bootraw" 65536
    mkfs.ext4 -F -b 4096 -L rootfs -m 0 -d "$rootstage" "$rootraw" 327680
  '
  img2simg "$bootraw" "$bootsparse"
  img2simg "$rootraw" "$rootsparse"
  rm -f "$bootraw" "$rootraw"

  cp "$LEGACY_DIR/base/gpt_both0.bin" "$PKGDIR/"
  cp "$LEGACY_DIR/base/aboot.bin" "$PKGDIR/"
  cp "$LEGACY_DIR/base/hyp.mbn" "$PKGDIR/"
  cp "$LEGACY_DIR/base/rpm.mbn" "$PKGDIR/"
  cp "$LEGACY_DIR/base/sbl1.mbn" "$PKGDIR/"
  cp "$LEGACY_DIR/base/tz.mbn" "$PKGDIR/"
  cp "$LEGACY_DIR/base/sbc_1.0_8016.bin" "$PKGDIR/"
  cp "$LEGACY_DIR/base/lk2nd.img" "$PKGDIR/" || true

  cat > "$PKGDIR/flash_from_fastboot.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for f in gpt_both0.bin aboot.bin hyp.mbn rpm.mbn sbl1.mbn tz.mbn sbc_1.0_8016.bin boot.bin rootfs.bin; do
  [ -f "$f" ] || { echo "missing: $f"; exit 1; }
done
read -r -p 'Continue and modify the device partition table? [yes/NO] ' ans
[ "$ans" = yes ] || { echo 'aborted'; exit 1; }
fastboot erase boot || true
fastboot flash aboot aboot.bin
fastboot reboot
sleep 5
for n in fsc fsg modemst1 modemst2; do
  fastboot oem dump "$n" && fastboot get_staged "$n.bin" || true
done
fastboot erase boot || true
fastboot reboot bootloader
sleep 5
fastboot flash partition gpt_both0.bin
fastboot flash hyp hyp.mbn
fastboot flash rpm rpm.mbn
fastboot flash sbl1 sbl1.mbn
fastboot flash tz tz.mbn
[ -f fsc.bin ] && fastboot flash fsc fsc.bin || true
[ -f fsg.bin ] && fastboot flash fsg fsg.bin || true
[ -f modemst1.bin ] && fastboot flash modemst1 modemst1.bin || true
[ -f modemst2.bin ] && fastboot flash modemst2 modemst2.bin || true
fastboot flash aboot aboot.bin
fastboot flash cdt sbc_1.0_8016.bin
fastboot erase boot || true
fastboot erase rootfs || true
fastboot reboot
sleep 8
fastboot devices
fastboot flash boot boot.bin
echo '[INFO] Using -S 128M to avoid host-side sparse read issues on some fastboot builds'
fastboot -S 128M flash rootfs rootfs.bin
fastboot reboot
EOF
  chmod 755 "$PKGDIR/flash_from_fastboot.sh"

  cat > "$PKGDIR/README-flash.md" <<'EOF'
# UFI001C Debian 13 Hybrid Slim

This bundle contains a **Debian 13 (Trixie)** rootfs combined with a **postmarketOS MSM8916 kernel (6.12.1-r2)** and the legacy OpenStick low-level boot chain.

## Default access
- USB network: `ssh user@192.168.5.1` password: `1`
- Wi-Fi AP: SSID `Openstick`, password `openstick`
- Serial console: `ttyMSM0` autologin as `root`

## Notes
- The partition table is modified.
- Keep backups of board-specific modem state partitions whenever possible.
- Use `boot.bin` and `rootfs.bin` for fastboot flashing.
- The first boot generates missing SSH host keys and finishes system setup.
EOF

  (
    cd "$PKGDIR"
    sha256sum * > SHA256SUMS
  )

  python3 - <<PY
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
pkgdir = Path('$PKGDIR')
zipfile = Path('$ARTIFACTS/$IMAGE_NAME.zip')
with ZipFile(zipfile, 'w', compression=ZIP_DEFLATED, compresslevel=9) as zf:
    for p in sorted(pkgdir.rglob('*')):
        if p.is_file():
            zf.write(p, p.relative_to(pkgdir))
print(zipfile)
PY
}

main() {
  require_tools
  prepare_dirs
  fetch_assets
  bootstrap_rootfs
  configure_rootfs
  enable_units
  prune_rootfs
  create_artifacts
  log "Done: $ARTIFACTS/$IMAGE_NAME.zip"
}

main "$@"
