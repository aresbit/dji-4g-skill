#!/bin/sh
# dji-4g-skill — 只读预检：模块在不在、驱动绑没绑、AT 口是哪个、谁在抢串口
# 不做任何修改。新机器上先跑这个。
set -eu

DJI_VIDPID="${DJI_VIDPID:-2ca3:4006}"   # 出厂值；伪装后为 2c7c:0125
ALT_VIDPID="2c7c:0125"

hr()  { printf -- '---- %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

hr "0/6 平台"
[ "$(uname -s)" = "Linux" ] || { bad "本 skill 只覆盖 Linux（macOS 请用 dji-4g-sim-skill）"; exit 1; }
ok "$(uname -s) $(uname -r) / $(uname -m)"

hr "1/6 USB 层"
if lsusb 2>/dev/null | grep -q "$DJI_VIDPID"; then
    ok "出厂身份 $DJI_VIDPID 在总线上"
    VIDPID="$DJI_VIDPID"
elif lsusb 2>/dev/null | grep -qi "$ALT_VIDPID"; then
    ok "已是 Quectel 身份 $ALT_VIDPID（已完成伪装）"
    VIDPID="$ALT_VIDPID"
else
    bad "未检测到大疆 4G 模块（$DJI_VIDPID / $ALT_VIDPID 都没有）"
    warn "排查顺序："
    warn "  ① USB-C 线是否支持数据传输（头号原因，换线再试）"
    warn "  ② 换端口，优先机身直连口，别用 Hub"
    warn "  ③ 重新插拔；确认插到底"
    warn "详见 references/troubleshooting.md #1"
    warn "注意：模块绿灯亮只证明【供电】通了，不证明数据线通了。"
    exit 2
fi

hr "2/6 内核驱动 / 设备节点"
printf '  ttyUSB : '; ls /dev/ttyUSB* 2>/dev/null | tr '\n' ' ' || true; echo
printf '  cdc-wdm: '; ls /dev/cdc-wdm* 2>/dev/null | tr '\n' ' ' || printf '(无)'; echo
[ -e /dev/ttyUSB0 ] && ok "AT 串口已就绪" || warn "无 ttyUSB —— 需先跑 sudo scripts/bind_at.sh"
if ls /dev/cdc-wdm* >/dev/null 2>&1; then
    ok "QMI 控制口在 → vohive 可用 qmi 后端（能上网）"
else
    warn "无 cdc-wdm* —— 模块不在 QMI 模式，vohive 只能用 at 后端（只能管卡，不能上网）"
fi

hr "3/6 网络接口"
ip -br link 2>/dev/null | while read -r name state _; do
    case "$name" in
        enx*|wwan*|usb*) printf '  模块网卡: %s %s\n' "$name" "$state" ;;
    esac
done
ip -br addr 2>/dev/null | grep -E 'enx|wwan' || warn "模块网卡尚无 IP（未建立数据连接属正常）"

hr "4/6 默认路由（防偷跑流量）"
DEF=$(ip route show default 2>/dev/null | head -1)
[ -n "$DEF" ] && ok "$DEF" || warn "无默认路由"
case "$DEF" in
    *enx*|*wwan*) bad "默认路由走了 4G 模块 —— 非预期的话流量正在计费！" ;;
    *) ok "默认路由不在模块上 ✓" ;;
esac

hr "5/6 抢串口进程"
if pgrep -x ModemManager >/dev/null 2>&1; then
    bad "ModemManager 正在运行（PID $(pgrep -x ModemManager | head -1)）"
    warn "它会独占 AT 口，导致手工 AT 查询【返回空】而不是报错。"
    warn "用 vohive 或手工 AT 前必须：sudo systemctl stop ModemManager"
fi
if pgrep -f 'vohive' >/dev/null 2>&1; then
    warn "vohive 正在运行 —— 它也会独占 AT 口"
    warn "要手工发 AT，先停 vohive；或改用本 skill 的 status.sh 只读诊断。"
fi
# 无论谁占用，列出来
for p in /dev/ttyUSB0 /dev/ttyUSB1 /dev/ttyUSB2 /dev/ttyUSB3; do
    [ -e "$p" ] || continue
    holder=$(lsof "$p" 2>/dev/null | tail -n +2 | awk '{print $1"("$2")"}' | head -1)
    [ -n "$holder" ] && printf '    %s 被占用: %s\n' "$p" "$holder"
done
pgrep -x ModemManager >/dev/null 2>&1 || pgrep -f 'vohive' >/dev/null 2>&1 \
    || ok "没有进程占用 AT 串口"

hr "6/6 模块身份与模式（读到 ttyUSB 才会执行）"
ATPORT=""
for p in /dev/ttyUSB3 /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB0; do
    [ -e "$p" ] || continue
    r=$(printf 'AT\r' | timeout 2 python3 -c "
import sys,serial
try:
    s=serial.Serial('$p',115200,timeout=1.2); s.dtr=True; s.rts=True
    s.write(b'AT\r'); import time; time.sleep(0.4)
    print(s.read(100).decode('utf-8','replace').strip()); s.close()
except Exception: pass
" 2>/dev/null || true)
    if [ -n "$r" ]; then ATPORT="$p"; break; fi
done
if [ -n "$ATPORT" ]; then
    ok "AT 口 = $ATPORT"
    warn "后续可用: sudo scripts/at_tool.py --port $ATPORT probe"
else
    warn "未找到响应 AT 的串口。常见原因（按概率）："
    warn "  · ModemManager 或 vohive 正独占 AT 口 → 先停它们"
    warn "  · 驱动未绑 → sudo scripts/bind_at.sh"
    warn "  · 未拉 DTR/RTS（本脚本已处理）"
fi

printf '\n预检结束（未做任何改动）。\n'
