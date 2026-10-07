#!/bin/sh
# dji-4g-skill — 部署并启动 vohive
#
# 做四件事：停 ModemManager → 取 IMEI → 写 config → 下载二进制并启动
#
# 用法：
#   scripts/setup_vohive.sh                      # 自动探测 IMEI，默认 at 后端
#   scripts/setup_vohive.sh --imei 866069050458254
#   scripts/setup_vohive.sh --backend qmi        # 要上网必须用 qmi（需模块在 QMI 模式）
#   scripts/setup_vohive.sh --dir ~/vohive --port 7575
#   scripts/setup_vohive.sh --binary /path/to/vohive   # 用已有二进制，跳过下载
set -eu

DIR="${HOME}/vohive"
PORT=7575
IMEI=""
BINARY=""
BACKEND="${VOHIVE_BACKEND:-at}"   # at=只能管卡 / qmi=可上网（需模块在 QMI 模式）
# release 源（第三方镜像）。vohive 本体：github.com/aresbit/vohive
REL_REPO="${VOHIVE_REL_REPO:-Jane-Rui/vohive-release}"

while [ $# -gt 0 ]; do
    case "$1" in
        --imei)    IMEI="$2"; shift 2 ;;
        --dir)     DIR="$2"; shift 2 ;;
        --port)    PORT="$2"; shift 2 ;;
        --binary)  BINARY="$2"; shift 2 ;;
        --backend) BACKEND="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 1 ;;
    esac
done

HR() { printf -- '---- %s\n' "$*"; }

HR "1/4 停止 ModemManager（它会独占 AT 口）"
if pgrep -x ModemManager >/dev/null 2>&1; then
    sudo systemctl stop ModemManager
    echo "  已停止（恢复：sudo systemctl start ModemManager）"
else
    echo "  未运行，跳过"
fi

HR "2/4 确定设备 IMEI"
HERE=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
if [ -z "$IMEI" ]; then
    IMEI=$(sudo python3 "$HERE/at_tool.py" read 'AT+CGSN' 2>/dev/null \
           | tr -dc '0-9' | tail -c 15 || true)
fi
[ -n "$IMEI" ] || { echo "  取不到 IMEI。请手动指定：--imei <15位>" >&2; exit 1; }
echo "  IMEI = $IMEI"
echo "  （vohive 靠 IMEI 认设备；config 里不写 modem_imei 就永远认不到）"

HR "3/4 写配置 $DIR/config/config.yaml"
mkdir -p "$DIR/config" "$DIR/data" "$DIR/logs"
cat > "$DIR/config/config.yaml" <<EOF
server:
    debug: false
    port: $PORT

web:
    username: admin
    password: admin123        # ← 改掉！WebUI 默认监听所有网卡

devices:
    - device_backend: $BACKEND
      id: dji-4g-1
      name: "DJI 4G (QDC507)"
      modem_imei: "$IMEI"

telegram: {enabled: false}
feishu:   {enabled: false}
qq:       {enabled: false}
webhook:  {enabled: false}
bark:     {enabled: false}
email:    {enabled: false}
pushplus: {enabled: false}
EOF
echo "  已写入"

HR "4/4 准备并启动 vohive"
cd "$DIR"
if [ -n "$BINARY" ]; then
    cp "$BINARY" ./vohive
else
    if [ -x ./vohive ]; then
        echo "  已有 ./vohive，跳过下载"
    else
        echo "  从 $REL_REPO 下载 release 二进制…"
        URL=$(gh api "repos/$REL_REPO/releases/latest" \
              --jq '.assets[] | select(.name|test("linux_amd64$")) | .browser_download_url' 2>/dev/null | head -1)
        [ -n "$URL" ] || { echo "  取不到下载地址；请用 --binary 指定" >&2; exit 1; }
        echo "  $URL"
        curl -fL --progress-bar "$URL" -o ./vohive
        chmod +x ./vohive
    fi
fi

sudo nohup ./vohive > logs/run.log 2>&1 &
sleep 10
if ss -ltn 2>/dev/null | grep -q ":$PORT"; then
    echo "  ✓ 已启动，监听 :$PORT"
else
    echo "  ! 端口未监听，查日志：$DIR/logs/run.log" >&2
    tail -20 "$DIR/logs/run.log" >&2 || true
    exit 1
fi

printf '\n完成。\n'
echo "  WebUI     : http://127.0.0.1:$PORT   (admin / admin123)"
echo "  日志      : $DIR/logs/run.log"
echo "  诊断      : $HERE/status.sh"
echo
if [ "$BACKEND" = "at" ]; then
    echo "  当前后端 = at：可管卡（AT/短信/eSIM），但【不能上网】。"
    echo "  要上网：切 QMI 模式后改用 --backend qmi，再调 PATCH /api/devices/<id>/network"
    echo "  详见 SKILL.md 的《上网（数据连接）》一节。"
else
    echo "  当前后端 = $BACKEND：具备网络控制能力。"
    echo "  下一步开数据："
    echo "    TOKEN=\$(curl -s -X POST http://127.0.0.1:$PORT/api/auth/login \\"
    echo "      -H 'Content-Type: application/json' \\"
    echo "      -d '{\"username\":\"admin\",\"password\":\"admin123\"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"token\"])')"
    echo "    curl -X PATCH http://127.0.0.1:$PORT/api/devices/<id>/network \\"
    echo "      -H \"Authorization: Bearer \$TOKEN\" -H 'Content-Type: application/json' \\"
    echo "      -d '{\"enabled\":true,\"apn\":\"cmnet\",\"ip_version\":\"ipv4\"}'"
    echo "  开完记得配策略路由，否则 4G 出不去：sudo $HERE/route_4g.sh"
fi
echo
echo "  安全提醒：WebUI 默认监听 *:$PORT（局域网可达）+ 默认密码。"
echo "            建议改密码，或绑到 127.0.0.1。"
echo "  持久化  ：当前是 nohup 前台进程，重启失效；需长期用请做成 systemd 服务。"
