#!/bin/sh
# dji-4g-skill — 给 4G 网卡配置【基于源地址的策略路由】
#
# 为什么需要：Linux 的路由查找只看 metric，不看源地址属于哪张网卡。
# 双默认路由时 wifi（metric 600）永远胜过 4G（metric 5000），所以
#     ip route get 1.1.1.1 from <4G源地址>  →  via <wifi网关> dev wlp...
# 4G 源包从 wifi 出去，源地址不属于 wifi → 被丢弃。表现是「vohive 说连上了、
# 拿到了公网 IP，但 curl 就是超时」。
#
# 解法：为 4G 源地址单开一张路由表 + 一条规则。
#
# ⚠️ 本脚本的改动【重启后失效】。要持久化见文件末尾说明。
#
# 用法：
#   sudo scripts/route_4g.sh                 # 自动探测 4G 网卡与网关
#   sudo scripts/route_4g.sh --iface wwan0 --ip 10.67.120.102 --gw 10.67.120.101
#   sudo scripts/route_4g.sh --clean         # 撤掉规则与表
#   scripts/route_4g.sh --show               # 只读：看当前状态
set -eu

TABLE=200
PRIO=100
IFACE=""; IP=""; GW=""; ACTION=setup

while [ $# -gt 0 ]; do
    case "$1" in
        --iface) IFACE="$2"; shift 2 ;;
        --ip)    IP="$2";    shift 2 ;;
        --gw)    GW="$2";    shift 2 ;;
        --table) TABLE="$2"; shift 2 ;;
        --clean) ACTION=clean; shift ;;
        --show)  ACTION=show;  shift ;;
        --watch) ACTION=watch; shift ;;
        --install-service) ACTION=install; shift ;;
        --uninstall-service) ACTION=uninstall; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 1 ;;
    esac
done

# ---- 自动探测 ----
detect() {
    [ -n "$IFACE" ] || IFACE=$(ip -br link 2>/dev/null | awk '/^(wwan|enx|usb)/{print $1; exit}')
    [ -n "$IP" ] || IP=$(ip -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' \
                         | grep -E '^[0-9]+\.' | cut -d/ -f1 | head -1)
    [ -n "$GW" ] || GW=$(ip route show dev "$IFACE" 2>/dev/null \
                         | awk '/default via/{print $3; exit}')
    # 兜底：QMI 场景网关常是网段内 .1（/30 时是 base+1）
    if [ -z "$GW" ] && [ -n "$IP" ]; then
        base=$(echo "$IP" | awk -F. '{printf "%s.%s.%s",$1,$2,$3}')
        last=$(echo "$IP" | awk -F. '{print $4}')
        # /30 下 base+1 是网关；否则用 base.1
        GW="$base.1"
        case "$last" in
            10[0-9]|1[0-9][0-9]|2[0-9][0-9]) GW=$(printf '%s.%d' "$base" $((last & ~1 | 1))) ;;
        esac
    fi
}

case "$ACTION" in
    install|uninstall)
        UNIT=/etc/systemd/system/dji-4g-route.service
        if [ "$ACTION" = "uninstall" ]; then
            [ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo $0 --uninstall-service" >&2; exit 1; }
            systemctl disable --now dji-4g-route.service 2>/dev/null || true
            rm -f "$UNIT"; systemctl daemon-reload
            echo "已卸载 dji-4g-route.service"
            exit 0
        fi
        [ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo $0 --install-service" >&2; exit 1; }
        SELF=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
        cat > "$UNIT" <<EOF
[Unit]
Description=DJI 4G module source-based policy routing (auto-reapply on IP change)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$SELF --watch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now dji-4g-route.service
        sleep 3
        echo "已安装并启动 dji-4g-route.service"
        systemctl --no-pager --lines=0 status dji-4g-route.service 2>&1 | head -6
        exit 0
        ;;
    watch)
        # 长驻：盯着 4G 网卡的地址变化，一变就重配策略路由。
        # 因为 DHCP/QMI 每次重拨都会换 IP，静态规则必然失效。
        [ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo $0 --watch" >&2; exit 1; }
        detect
        [ -n "$IFACE" ] || { echo "找不到 4G 网卡" >&2; exit 1; }
        echo "监听 $IFACE 的地址变化（Ctrl-C 退出）…"
        # 启动时先配一次
        "$0" --iface "$IFACE" >/dev/null 2>&1 || true
        # ip monitor 会持续输出；每收到一行就重配
        ip monitor address dev "$IFACE" 2>/dev/null | while read -r _line; do
            sleep 1                     # 等地址配置稳定
            if "$0" --iface "$IFACE" >/dev/null 2>&1; then
                NOW=$(ip -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | grep -E '^[0-9]+\.' | cut -d/ -f1 | head -1)
                echo "$(date '+%F %T') 地址变化 → 已重配策略路由 (源地址 ${NOW:-?})"
            fi
        done
        exit 0
        ;;
    show)
        detect
        echo "网卡  : ${IFACE:-未探测}"
        echo "源地址: ${IP:-未探测}"
        echo "网关  : ${GW:-未探测}"
        echo "--- 规则 ---"
        ip rule show 2>/dev/null | grep -E "lookup $TABLE" || echo "(无 table $TABLE 的规则)"
        echo "--- table $TABLE ---"
        ip route show table $TABLE 2>/dev/null || echo "(空)"
        exit 0
        ;;
    clean)
        [ -n "$IP" ] || detect
        if [ -n "$IP" ]; then
            ip rule del from "$IP" lookup "$TABLE" 2>/dev/null || true
        fi
        ip route flush table "$TABLE" 2>/dev/null || true
        echo "已撤销 table $TABLE 的规则与路由。"
        exit 0
        ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo $0" >&2; exit 1; }
detect
[ -n "$IFACE" ] || { echo "找不到 4G 网卡（wwan*/enx*/usb*）" >&2; exit 1; }
[ -n "$IP" ]    || { echo "网卡 $IFACE 没有 IPv4。先让 vohive/MM 把数据网络拉起来。" >&2; exit 1; }
[ -n "$GW" ]    || { echo "推不出网关，请用 --gw 指定" >&2; exit 1; }

echo "网卡  : $IFACE"
echo "源地址: $IP"
echo "网关  : $GW"

# 清掉本表所有陈旧规则（IP 重拨后会变，旧规则必须删，否则规则越积越多且指向已失效的源地址）
OLD=$(ip rule show 2>/dev/null | awk -v t="$TABLE" '$0 ~ ("lookup " t "$") {gsub(":","",$1); print $1}')
for p in $OLD; do
    ip rule del priority "$p" 2>/dev/null && echo "  清除旧规则 priority=$p"
done

# 链路路由（保证网关本身可达，否则下一跳不可达）
ip route replace "$GW/32" dev "$IFACE" table "$TABLE" 2>/dev/null || true
ip route replace default via "$GW" dev "$IFACE" table "$TABLE"
ip rule add from "$IP" lookup "$TABLE" priority "$PRIO" 2>/dev/null || true

# 清掉其他表里可能残留的、指向本网卡的默认路由（避免误导）
ip route del default dev "$IFACE" metric 30000 2>/dev/null || true

echo
echo "已配置策略路由。验证："
echo "  ip route get 1.1.1.1 from $IP        # 应显示 table $TABLE / dev $IFACE"
echo "  curl -s --interface $IFACE --noproxy '*' https://myip.ipip.net"
echo
echo "注意两条硬规则："
echo "  1) 绑【网卡名 $IFACE】，不要绑源 IP —— 实测绑 IP 会失败"
echo "  2) --noproxy '*' 必需 —— 本机有 HTTP(S)_PROXY 时，curl 会去连"
echo "     【本地代理】而源地址被绑成 4G，必然失败，看着像 4G 不通"
echo
echo "IP 会随重拨变化 → 建议装成服务自动跟随："
echo "  sudo $0 --install-service"

cat <<'EOF'

持久化（重启后不丢）——二选一：
  A. NetworkManager 连接加 dispatcher 脚本，在 up 时执行本脚本
  B. 写 systemd unit（ExecStart=本脚本），网络就绪后运行
  C. 最简单：加一条 networkd-dispatcher 或 /etc/network/if-up.d/ 脚本
EOF
