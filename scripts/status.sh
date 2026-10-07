#!/bin/sh
# dji-4g-skill — 只读诊断：模块在不在、什么模式、出口是谁、能不能真出网
# 随时可跑，不做任何修改。--no-egress 可跳过出网测试（省流量）。
set -eu

DO_EGRESS=1
for a in "$@"; do
    case "$a" in
        --no-egress) DO_EGRESS=0 ;;
        -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
        *) echo "未知参数：$a" >&2; exit 1 ;;
    esac
done

HERE=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
hr()  { printf -- '\n---- %s\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

hr "1/5 模块在不在"
if ! lsusb | grep -Eqi '2ca3:4006|2c7c:0125'; then
    bad "USB 上找不到模块"
    warn "查 references/troubleshooting.md #1（充电线是头号原因）"
    exit 2
fi
lsusb | grep -Ei '2ca3:4006|2c7c:0125' | sed 's/^/  /'

hr "2/5 驱动与节点"
printf '  ttyUSB   : '; ls /dev/ttyUSB* 2>/dev/null | tr '\n' ' ' || printf '(无)'; echo
printf '  cdc-wdm  : '; ls /dev/cdc-wdm* 2>/dev/null | tr '\n' ' ' || printf '(无)'; echo
[ -e /dev/ttyUSB0 ] || warn "无 ttyUSB：sudo scripts/bind_at.sh"
if ls /dev/cdc-wdm* >/dev/null 2>&1; then
    ok "QMI 控制口在 → vohive 可用 qmi 后端（能上网）"
else
    warn "无 cdc-wdm*：模块不在 QMI 模式 → vohive 只能用 at 后端（只能管卡，不能上网）"
    warn "  要上网：sudo scripts/at_tool.py write 'AT+QCFG=\"usbnet\",0' 然后重启模块"
fi

hr "3/5 抢口进程"
if pgrep -x ModemManager >/dev/null 2>&1; then
    bad "ModemManager 在跑 —— 会独占 AT 口，读到的 AT 响应会是【空】而非报错"
    warn "sudo systemctl stop ModemManager"
else
    ok "ModemManager 未运行"
fi

hr "4/5 默认出口（会不会偷跑流量）"
DEF=$(ip route show default 2>/dev/null | head -1)
echo "  $DEF"
case "$DEF" in
    *enx*|*wwan*) bad "默认路由在 4G 模块上 —— 流量正在走 SIM 计费！" ;;
    *) [ -n "$DEF" ] && ok "默认出口不在模块上 ✓" ;;
esac
# 策略路由是 4G 能出网的关键（否则 4G 源包会从 wifi 出去被丢）
MODIF=$(ip -br link 2>/dev/null | awk '/^(wwan|enx|usb)/{print $1; exit}')
if [ -n "$MODIF" ]; then
    if ip rule show 2>/dev/null | grep -q 'lookup 200'; then
        ok "已配 4G 策略路由 (table 200)"
    else
        warn "没有 4G 策略路由 —— 4G 可能『vohive 说连上了但 curl 超时』"
        warn "  sudo scripts/route_4g.sh"
    fi
fi

hr "5/5 上层链路与出网"
IFACE=$(ip -br link 2>/dev/null | awk '/^(enx|wwan)/{print $1; exit}')
if [ -z "$IFACE" ]; then
    warn "没有模块网卡（模块不在 ECM/RNDIS/QMI 上网模式？）"
else
    echo "  模块网卡: $IFACE"
    ip -br addr show "$IFACE" | sed 's/^/  /'
    IP=$(ip -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | grep -E '^[0-9]+\.' | cut -d/ -f1 | head -1)
    if [ -z "$IP" ]; then
        warn "网卡没有 IPv4。ECM 模式常不响应 DHCP，可静态配："
        warn "  sudo ip addr add 192.168.225.2/24 dev $IFACE"
    else
        ok "IPv4 = $IP"
        if [ "$DO_EGRESS" = "1" ]; then
            echo "  → 绑【网卡名】实测出网（不要绑源 IP，实测绑 IP 会失败）"
            OUT=""
            # 首次请求可能因运营商建链延迟而超时，重试几次再下结论
            i=0
            while [ "$i" -lt 3 ]; do
                OUT=$(timeout 20 curl -s --interface "$IFACE" --noproxy '*' \
                      --max-time 15 https://myip.ipip.net 2>/dev/null || true)
                [ -n "$OUT" ] && break
                i=$((i+1)); sleep 2
            done
            if [ -n "$OUT" ]; then
                ok "出网正常（第 $((i+1)) 次尝试）：$OUT"
                case "$OUT" in
                    *移动*|*联通*|*电信*|*Mobile*|*Unicom*|*Telecom*) : ;;
                    *) warn "出口不像运营商 IP —— 可能走了 wifi，检查策略路由" ;;
                esac
            else
                bad "出网失败（已重试 3 次）"
                warn "按顺序排查："
                warn "  · 策略路由是否为【当前】IP？ sudo scripts/route_4g.sh   （#8b）"
                warn "  · 是否绑成了源 IP？（必须绑网卡名）                 （#8c）"
                warn "  · 代理环境变量？脚本已加 --noproxy '*'              （#8c）"
                warn "  · SIM 欠费？充值后需重建 PDP                        （#8d）"
                warn "  · 模块自己也出不去？ AT+QPING 测试 —— 那就是卡侧问题"
                warn "  · 别用 ping 判断 —— 运营商常封 ICMP                （#9）"
            fi
        fi
    fi
fi

hr "vohive（若已部署）"
if pgrep -f 'vohive' >/dev/null 2>&1; then
    ok "进程在跑"
    for p in 7575 8080; do
        ss -ltn 2>/dev/null | grep -q ":$p " && echo "  监听 :$p"
    done
else
    warn "未运行。部署：scripts/setup_vohive.sh"
fi

printf '\n诊断结束（只读，未做改动）。\n'
warn "分享日志/截图前抹掉 EID、ICCID、IMSI、完整手机号、短信验证码。"
