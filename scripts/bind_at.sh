#!/bin/sh
# dji-4g-skill — 把 option 驱动绑到大疆 4G 模块的 Vendor 接口上，创建 AT 串口 /dev/ttyUSB*
#
# 为什么需要这一步：内核对 2ca3:4006 没有内置的接口号映射，
# 所以 4 个 Vendor Specific 接口默认无人认领，不会出现 ttyUSB。
# 用 new_id 让 option 驱动接管它们。
#
# 幂等：已绑过就跳过。需要 root。
set -eu

VID="${DJI_VID:-2ca3}"
PID="${DJI_PID:-4006}"

if [ "$(id -u)" -ne 0 ]; then
    echo "需要 root：sudo $0" >&2
    exit 1
fi

NEWID="/sys/bus/usb-serial/drivers/option1/new_id"

if ls /dev/ttyUSB* >/dev/null 2>&1; then
    echo "已有 AT 串口，跳过绑定：$(ls /dev/ttyUSB* | tr '\n' ' ')"
    exit 0
fi

[ -e "$NEWID" ] || { echo "找不到 $NEWID —— 先 modprobe option" >&2; }

echo "加载 option 驱动…"
modprobe option

echo "绑定 $VID $PID …"
printf '%s %s\n' "$VID" "$PID" > "$NEWID"

# 等 udev 把节点建出来
i=0
while [ "$i" -lt 15 ]; do
    if ls /dev/ttyUSB* >/dev/null 2>&1; then break; fi
    sleep 0.4; i=$((i+1))
done

if ls /dev/ttyUSB* >/dev/null 2>&1; then
    echo "OK，AT 串口：$(ls /dev/ttyUSB* | tr '\n' ' ')"
    echo
    echo "下一步：确认哪个口是 AT（不要假设是 ttyUSB2，实测为准）"
    echo "  sudo scripts/at_tool.py probe"
    echo
    echo "注意：若 ModemManager 在跑，它会独占 AT 口，你会读到空响应。"
    echo "  sudo systemctl stop ModemManager"
else
    echo "绑定后仍未出现 ttyUSB —— 检查 dmesg | tail -20" >&2
    exit 1
fi
