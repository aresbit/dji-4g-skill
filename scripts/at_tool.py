#!/usr/bin/env python3
"""dji-4g-skill — AT 指令工具（EG25-G / QDC507）

用法：
  sudo scripts/at_tool.py probe                  # 找 AT 口 + 只读体检
  sudo scripts/at_tool.py --port /dev/ttyUSB3 read 'AT+CSQ'
  sudo scripts/at_tool.py --port /dev/ttyUSB3 write 'AT+CGDCONT=1,"IP","cmnet"'
  sudo scripts/at_tool.py listen                 # 抓自发上报（URC）

两个容易踩的点，本工具已处理：
  1. 打开串口必须显式拉高 DTR/RTS，否则模块不回应（表现为"空响应"）。
  2. AT 口不一定是 ttyUSB2，必须实测（probe 会自动找）。
"""
import argparse
import glob
import os
import subprocess
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("需要 pyserial：pip3 install pyserial")

BAUD = 115200

# 只读体检指令（不改变模块状态）
READONLY = [
    ("AT", "握手"),
    ("ATI", "模块型号"),
    ("AT+CPIN?", "SIM 状态（READY=有卡）"),
    ("AT+CSQ", "信号质量"),
    ("AT+CFUN?", "功能模式（1=全功能）"),
    ("AT+CREG?", "2/3G 注册"),
    ("AT+CGREG?", "GPRS 注册"),
    ("AT+CEREG?", "LTE 注册"),
    ("AT+CGATT?", "PS 附着（1=已附着）"),
    ("AT+COPS?", "当前运营商"),
    ("AT+QNWINFO", "网络信息"),
    ('AT+QCFG="usbnet"', "USB 模式（0=QMI 1=ECM 2=MBIM 3=RNDIS）"),
    ('AT+QCFG="usbcfg"', "VID/PID 与接口组合"),
    ("AT+CGDCONT?", "PDP/APN 配置"),
]

# 写入类指令关键词 —— 命中则要求确认
WRITE_HINTS = ("=", "CFUN=1,1")


def modemmanager_running() -> bool:
    try:
        return subprocess.run(["pgrep", "-x", "ModemManager"],
                              capture_output=True).returncode == 0
    except Exception:
        return False


def open_port(port):
    s = serial.Serial(port, BAUD, timeout=1.5)
    s.dtr = True          # ← 不拉高这两根线，模块不回话
    s.rts = True
    time.sleep(0.3)
    s.reset_input_buffer()
    return s


def send(s, cmd, wait=0.6, echo=None):
    """发一条 AT 指令，返回去掉回显后的响应文本。"""
    s.reset_input_buffer()
    s.write((cmd + "\r").encode())
    time.sleep(wait)
    raw = s.read(2048).decode("utf-8", "replace").strip()
    skip = {cmd} if echo is None else {cmd}
    lines = [l.strip() for l in raw.splitlines() if l.strip() and l.strip() not in skip]
    return " | ".join(lines)


def find_at_port(verbose=False):
    """逐个 ttyUSB 发 AT，返回第一个回 OK 的口。"""
    for p in sorted(glob.glob("/dev/ttyUSB*"),
                    key=lambda x: x[::-1]):   # ttyUSB3,2,1,0 优先高编号
        try:
            s = open_port(p)
            r = send(s, "AT")
            s.close()
            if verbose:
                print(f"    {p}: {r!r}")
            if "OK" in r:
                return p
        except Exception as e:
            if verbose:
                print(f"    {p}: 打开失败 {e}")
    return None


def cmd_probe(args):
    print("=== 查找 AT 口 ===")
    port = args.port or find_at_port(verbose=True)
    if not port:
        print("✗ 没有串口响应 AT。常见原因：")
        print("  · ModemManager 独占 → sudo systemctl stop ModemManager")
        print("  · 驱动未绑 → sudo scripts/bind_at.sh")
        return 1
    print(f"✓ AT 口 = {port}\n")

    if modemmanager_running():
        print("! ModemManager 在运行，读到的响应可能为空或残缺。")
        print("  建议先：sudo systemctl stop ModemManager\n")

    s = open_port(port)
    send(s, "ATE0")   # 关回显，响应更干净
    for cmd, desc in READONLY:
        print(f"  {cmd:<22} {desc}")
        print(f"      -> {send(s, cmd) or '(空)'}")
    s.close()

    print("\n=== 判读要点 ===")
    print("  CPIN=READY + CEREG=1/5 + CGATT=1  → 已附着运营商")
    print("  只拿到 192.168.225.x 不等于能上网，务必再用 curl 绑源地址实测出网。")
    return 0


def cmd_read(args):
    s = open_port(args.port)
    send(s, "ATE0")
    print(send(s, args.cmd, wait=1.0) or "(空)")
    s.close()
    return 0


def cmd_write(args):
    cmd = args.cmd
    if not args.yes:
        print(f"即将发送【写入类】AT 指令：\n\n    {cmd}\n")
        print("警告：此类指令可改变网络注册 / PDP / USB 模式 / SIM 状态，")
        print("      切错可能『既上不了网也切不回来』。确认影响后再继续。")
        if cmd.startswith("AT+QCFG=\"usbcfg\""):
            print("\n  · usbcfg 会写入模块 NV，永久生效（可用原值改回）")
        if cmd.startswith("AT+CFUN=1,1"):
            print("\n  · CFUN=1,1 会软重启模块，USB 会重新枚举")
        if cmd.startswith("AT+CGDCONT"):
            print("\n  · CGDCONT 设 APN，走 SIM 计费前先确认套餐/是否漫游")
        ans = input("\n确认发送？输入 yes 继续：").strip()
        if ans != "yes":
            print("已取消。")
            return 1

    if modemmanager_running():
        print("! 警告：ModemManager 在运行，会干扰写入。建议先停。")

    s = open_port(args.port)
    send(s, "ATE0")
    print(f"-> {send(s, cmd, wait=1.5) or '(空)'}")
    s.close()
    return 0


def cmd_listen(args):
    """抓自发上报（URC），例如来电、短信、网络变化。"""
    s = open_port(args.port)
    print(f"监听 {args.port}（Ctrl-C 退出）…")
    try:
        while True:
            data = s.read(4096)
            if data:
                sys.stdout.write(data.decode("utf-8", "replace"))
                sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        s.close()
    return 0


def main():
    ap = argparse.ArgumentParser(description="EG25-G / QDC507 AT 工具")
    ap.add_argument("--port", help="AT 串口，如 /dev/ttyUSB3（省略则自动探测）")
    sub = ap.add_subparsers(dest="action", required=True)

    sub.add_parser("probe", help="找 AT 口并做只读体检").set_defaults(func=cmd_probe)

    p = sub.add_parser("read", help="发只读指令")
    p.add_argument("cmd")
    p.set_defaults(func=cmd_read)

    p = sub.add_parser("write", help="发写入类指令（需确认）")
    p.add_argument("cmd")
    p.add_argument("--yes", "-y", action="store_true", help="跳过交互确认")
    p.set_defaults(func=cmd_write)

    sub.add_parser("listen", help="抓自发上报").set_defaults(func=cmd_listen)

    args = ap.parse_args()
    if args.action in ("read", "write", "listen") and not args.port:
        args.port = find_at_port()
        if not args.port:
            sys.exit("未找到 AT 口，请用 --port 指定，或先跑 probe")
        print(f"（自动选中 {args.port}）")
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
