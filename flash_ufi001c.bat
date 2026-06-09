@echo off
REM UFI-001C Debian 刷机脚本 (Windows)
REM
REM 使用方法:
REM   1. 将设备进入 EDL 9008 模式
REM   2. 将 OpenStick-Builder\files\ 目录中的镜像文件放在本脚本同一目录
REM   3. 以管理员身份运行本脚本
REM
REM ⚠️ 警告: 此操作会覆盖分区表，不可逆!

echo ============================================
echo  UFI-001C Debian 刷机脚本 (Windows)
echo ============================================
echo.
echo ⚠️  重要提醒:
echo   1. 请确保已备份原厂分区!
echo   2. 请确保设备已进入 EDL 9008 模式!
echo   3. 此操作将覆盖分区表，不可逆!
echo.

set /p CONFIRM="是否继续? (yes/no): "
if not "%CONFIRM%"=="yes" (
    echo 已取消
    pause
    exit /b 0
)

REM === 步骤 1: 检查文件 ===
if not exist "files\gpt_both0.bin" (
    echo 错误: 请先构建镜像
    pause
    exit /b 1
)

REM === 步骤 2: 备份原厂分区 ===
echo.
echo === 步骤 1: 备份原厂分区 ===
for %%p in (fsc fsg modem modemst1 modemst2 persist sec) do (
    echo   备份 %%p.bin ...
    edl r %%p %%p.bin
)

REM === 步骤 3: 刷入 aboot ===
echo.
echo === 步骤 2: 刷入 aboot (lk2nd) ===
edl w aboot files\aboot.mbn

REM === 步骤 4: 重启到 fastboot ===
echo.
echo === 步骤 3: 重启到 fastboot ===
edl e boot
edl reset
timeout /t 3

REM === 步骤 5: 刷写 ===
echo.
echo === 步骤 4: 刷写系统 ===
fastboot flash partition files\gpt_both0.bin
fastboot flash hyp files\hyp.mbn
fastboot flash rpm files\rpm.mbn
fastboot flash sbl1 files\sbl1.mbn
fastboot flash tz files\tz.mbn
fastboot flash aboot files\aboot.mbn
fastboot flash boot files\boot.bin
fastboot flash rootfs files\rootfs.bin

REM === 步骤 6: 恢复原厂分区 ===
echo.
echo === 步骤 5: 恢复原厂分区 ===
for %%p in (fsc fsg modem modemst1 modemst2 persist sec) do (
    if exist %%p.bin (
        echo   恢复 %%p.bin ...
        fastboot flash %%p %%p.bin
    )
)

REM === 步骤 7: 重启 ===
echo.
echo === 步骤 6: 重启 ===
fastboot reboot

echo.
echo ============================================
echo  刷机完成!
echo ============================================
echo.
echo 设备重启后:
echo   SSH: ssh user@192.168.5.1  密码: 1
echo   WiFi: SSID=Openstick, PWD=openstick
echo.
echo 首次启动后需修改设备树:
echo   sed -i 's/yiming-uz801v3/thwc-ufi001c/' /boot/extlinux/extlinux.conf
echo.
pause
