#!/usr/bin/env python3
"""dji-4g-skill — 把大疆一代 4G 模块 (2ca3:4006) 伪装成 Quectel EC25 (2c7c:0125)

为什么需要：vohive 源码 internal/device/discovery_compat.go 里写死
    if vid != 0x2c7c && vid != 0x05c6 { return CompatibleModem{}, false }
2ca3 被硬拒，所以必须改 VID/PID。

来源：sdrpsps/vohive-oneclick 附录 A（社区公开文档），非自创。

⚠️ 这是写入模块 NV 的操作，断电后仍生效。
   可回滚（--rollback 写回原值），但请先 --show 记录原值。

用法：
  sudo scripts/disguise_ec25.py --show       # 只读：看当前 VID/PID
  sudo scripts/disguise_ec25.py --apply      # 改成 EC25，并软重启
  sudo scripts/disguise_ec25.py --rollback   # 改回 2ca3:4006，并软重启
  （--no-reset 可跳过自动软重启，自行控制时机）
"""
import argparse
import glob
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("需要 pyserial：pip3 install pyserial")

# Quectel EC25 —— vohive 白名单放行
EC25_VID, EC25_PID = "0x2C7C", "0x0125"
# 大疆出厂值 —— 回滚用
DJI_VID, DJI_PID = "0x2CA3", "0x4006"


def find_port():
    for p in sorted(glob.glob("/dev/ttyUSB*"), key=lambda x: x[::-1]):
        try:
            s = serial.Serial(p, 115200, timeout=1.5)
            s.dtr = True; s.rts = True
            time.sleep(0.3); s.reset_input_buffer()
            s.write(b"AT\r"); time.sleep(0.4)
            r = s.read(200).decode("utf-8", "replace")
            s.close()
            if "OK" in r:
                return p
        except Exception:
            continue
    return None


def send(s, cmd, wait=1.2):
    s.reset_input_buffer()
    s.write((cmd + "\r").encode())
    time.sleep(wait)
    raw = s.read(1024).decode("utf-8", "replace").strip()
    return " | ".join(l.strip() for l in raw.splitlines() if l.strip() and l.strip() != cmd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--show", action="store_true", help="只读：显示当前 VID/PID")
    g.add_argument("--apply", action="store_true", help="伪装成 Quectel EC25")
    g.add_argument("--rollback", action="store_true", help="改回大疆原厂 2ca3:4006")
    ap.add_argument("--no-reset", action="store_true", help="不自动软重启")
    args = ap.parse_args()

    port = args.port or find_port()
    if not port:
        sys.exit("未找到 AT 口。先跑 scripts/at_tool.py probe 或 sudo scripts/bind_at.sh")

    s = serial.Serial(port, 115200, timeout=2.0)
    s.dtr = True; s.rts = True
    time.sleep(0.3); s.reset_input_buffer()
    send(s, "ATE0")

    cur = send(s, 'AT+QCFG="usbcfg"')
    print(f"AT 口: {port}")
    print(f"当前 usbcfg: {cur}")

    if args.show:
        s.close()
        return

    if args.apply:
        vid, pid = EC25_VID, EC25_PID
        what = f"Quectel EC25 ({vid}:{pid})"
    else:
        vid, pid = DJI_VID, DJI_PID
        what = f"大疆原厂 ({vid}:{pid})"

    print(f"\n即将把模块身份改为 {what}")
    print("  · 写入模块 NV，断电后仍生效")
    print("  · 操作期间请保持供电稳定，不要拔线")
    ans = input("输入 yes 继续：").strip()
    if ans != "yes":
        s.close()
        sys.exit("已取消。")

    cmd = f'AT+QCFG="usbcfg",{vid},{pid},1,1,1,1,1,0,0'
    print(f"\n发送: {cmd}")
    print(f"  -> {send(s, cmd, wait=1.5)}")

    print("\n校验（读回）：")
    print(f"  {send(s, 'AT+QCFG=\"usbcfg\"')}")

    if not args.no_reset:
        print("\n软重启模块使其重新枚举…")
        send(s, "AT+CFUN=1,1", wait=1.5)
        s.close()
        print("等待重新枚举（最多 30s）…")
        target = f"{vid[2:].lower()}:{pid[2:].lower()}"
        for i in range(15):
            time.sleep(2)
            import subprocess
            out = subprocess.run(["lsusb"], capture_output=True, text=True).stdout
            if target in out.lower():
                print(f"  ✓ 已出现 {target}")
                for line in out.splitlines():
                    if target in line.lower():
                        print(f"    {line.strip()}")
                break
        else:
            print(f"  ! 30s 内未见 {target}，检查 dmesg | tail -20")
        print("\n提示：重新枚举后 AT 口名字可能变化，重新跑 probe 确认。")
    else:
        s.close()

    print("\n回滚命令：sudo scripts/disguise_ec25.py --rollback")


if __name__ == "__main__":
    main()
