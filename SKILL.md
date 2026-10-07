---
name: dji-4g-skill
description: 在 Linux 主机上把大疆第一代 4G 模块（佰旺 QDC507 / Quectel EG25-G，出厂 USB 2ca3:4006）接入并拉起 vohive 管理平台——含 AT 串口打通、VID/PID 伪装成 Quectel EC25、ModemManager 冲突处理、vohive 部署与设备认领、以及"能不能上网"的正确判定方法。只要用户提到"大疆 4G 模块""DJI 4G""EG25G""QDC507""2ca3:4006""vohive""插了 4G 模块但电脑没反应""模块绿灯亮但认不到""4G 上网卡怎么在 Linux 上用""ModemManager 抢串口"，或在一块插了该模块的 Linux 机器上要求"拉起/部署/装好/看看能不能上网"，就使用本 skill——即使用户没说出"skill"两个字。也适用于诊断"模块能不能上网""为什么浏览器不走这张卡""AT 读不到""vohive 认不到设备"这类问题。
---

# 大疆 4G 模块（EG25-G / QDC507）Linux 接入与 vohive 拉起

## 这个 skill 解决什么

大疆第一代 4G 模块本质是 Quectel EG25-G，但出厂 USB ID 是 `2ca3:4006`（Baiwang/DJI）。
在 Linux 上把它跑通，有三个**互相独立**的坑，任何一个没解决都会表现为"认不到设备"：

1. **物理层** —— 很多人用的是 USB-C **充电线**（只供电不传数据）。此时模块**绿灯是亮的**，
   电脑却完全看不到它。必须换数据线。
2. **驱动层** —— 内核需要 `option`（AT 串口）和 `qmi_wwan`/`cdc_ether`（网络）驱动认领接口。
3. **应用层** —— vohive 源码里写死了 USB VID 白名单，只认 `0x2c7c`(Quectel) / `0x05c6`(Qualcomm)，
   `0x2ca3` 会被**硬拒**。所以必须把模块伪装成 Quectel EC25。

> **平台边界**：本 skill 覆盖 **Linux**。macOS 走的是完全不同的路子（libusb 直怼 USB 端点，
> 因为没有 Qualcomm 内核驱动），那是另一个 skill（`dji-4g-sim-skill`）的领域。
> 别把两者混用：在 Linux 上"绕过内核用 libusb"是逆流——内核已经把活干好了。

## 平台差异：为什么 macOS 能"直接用"

理解这一点能避免走错路：

| | macOS | Linux |
|---|---|---|
| Qualcomm 内核驱动 | **没有** | **有**（option / qmi_wwan / cdc_ether） |
| Vendor 接口归属 | 没人认领 → 用户态可用 | 被内核绑定占用 |
| 工具怎么做 | 用 libusb 自己抢过来，绕过 OS | 直接用内核给的 `/dev/ttyUSB*` + 网卡 |

macOS 是"没人管，所以我能直接管"；Linux 是"内核已经管了，你顺着用"。
所以在 Linux 上，**不要**去想怎么用 libusb 抢设备。

## 标准流程（四步）

每一步都先只读检测，确认后再动手。脚本都在 `scripts/`，全部可独立运行。

### 第一步——检测，什么都不改

```sh
scripts/preflight.sh
```

回答：模块在不在 USB 上、驱动绑了没、AT 口是哪个、有没有抢串口的进程。
**如果这里就报"未检测到模块"** → 头号原因是充电线，去读
`references/troubleshooting.md` #1。**不要在设备不上总线的情况下继续往下走**——
软件再怎么装都改变不了"总线上没有设备"。

### 第二步——打通 AT 串口

```sh
sudo scripts/bind_at.sh          # 绑 option 驱动，出 /dev/ttyUSB*
```

然后确认哪个是 AT 口（不能假设，要实测）：

```sh
sudo scripts/at_tool.py probe
```

它会逐口发 `AT`，选出回 `OK` 的那个。**注意两点**（都踩过）：
- 打开串口时必须显式 `dtr=True; rts=True`，否则模块不回话；
- AT 口**不一定是 ttyUSB2**，实测为准（本机是 ttyUSB3）。

同时要确认 **ModemManager 没在抢**：

```sh
sudo systemctl stop ModemManager
```

MM 会主动探测并独占 AT 口。它跑着的时候，你手工发 AT 会得到**空响应**而不是报错——
这个症状极易误判成"模块坏了"。

### 第三步——（仅当用 vohive）伪装成 EC25

vohive 的 `internal/device/discovery_compat.go` 里有：

```go
if vid != 0x2c7c && vid != 0x05c6 { return CompatibleModem{}, false }
```

`2ca3` 被直接拒绝。改 VID/PID：

```sh
sudo scripts/disguise_ec25.py --apply      # 写入模块 NV
sudo scripts/disguise_ec25.py --rollback   # 需要时改回 2ca3:4006
```

**这是写入模块 NV 的操作，永久生效。** 动手前：
- 确认设备确为对应型号、供电稳定；
- 先跑 `--show` 记录原值；
- 改完 `AT+CFUN=1,1` 重启模块，等待重新枚举为 `2c7c:0125 EC25 LTE modem`。

### 第四步——部署并启动 vohive

```sh
scripts/setup_vohive.sh --imei <模块IMEI>
```

它会下载二进制、按 IMEI 写配置、启动服务，并打印 WebUI 地址。

**vohive 靠 IMEI 认设备**，这点反直觉：`DeviceConfig` 里的 `ATPort` / `Interface` /
`USBPath` 全是 `mapstructure:"-"`，注释写着"运行时按 IMEI 现解析，绝不从文件读取"。
所以 **config 里不写 `modem_imei` 就永远认不到设备**，报错是
`未找到匹配的非 QMI 硬件（AT-only 或 MBIM），跳过启动`。

## 上网（数据连接）—— 与"管卡"是两回事 ⭐

**这是最容易走弯路的地方。** vohive 有两个互相独立的能力：

| 能力 | 需要什么 | 表现 |
|---|---|---|
| **管卡**（AT/短信/eSIM/读状态） | `device_backend: at`，`/dev/ttyUSB*` | 设备 `online`、`sms_enabled: true` |
| **上网**（建立数据连接） | **`device_backend: qmi`**，`/dev/cdc-wdm*` | `data_connected: true`、拿到 `public_ip` |

源码里写得很直白：

```go
NetworkCapable: mode == "qmi" || mode == "mbim"    // at 后端没有 NetworkController
```

在 `at` 后端下调"启用网络"接口，会得到
`{"message":"当前设备不支持网络控制"}`。

**所以：要上网就必须把模块切到 QMI 模式。**

### 切 QMI

```sh
# 模块侧（会立刻重新枚举，端口号会变）
scripts/at_tool.py write 'AT+QCFG="usbnet",0'
```

成功标志：出现 `/dev/cdc-wdm*` 和 `wwan0`，`lsusb -t` 里 `qmi_wwan` 绑到某接口。
然后把 vohive 配置改成 `device_backend: qmi` 重启。

### 然后在 vohive 里开数据（API）

```sh
PATCH /api/devices/<id>/network
{"enabled": true, "apn": "cmnet", "ip_version": "ipv4"}
```

成功响应里会直接给 `private_ip` 和 `public_ip`。

### 必须加【基于源地址的策略路由】⭐

**Linux 路由查找只看 metric，不看源地址属于哪张网卡。** 双默认路由时
wifi（metric 600）永远胜过 4G（metric 5000）：

```
ip route get 1.1.1.1 from 10.67.120.102
  →  via 192.168.3.1 dev wlp18s0      ← 4G 的源包从 wifi 出去了！
```

源地址不属于 wifi → 包被丢弃。**典型症状：vohive 说"数据网络已启动"、
也拿到了公网 IP，但 `curl` 就是超时。**

解法：

```sh
sudo scripts/route_4g.sh      # 自动探测网卡/源地址/网关并配策略路由
```

（本脚本改动重启后失效，文件末尾有持久化说明。）

### 测出网：两条硬规则 ⭐

```sh
curl -s --interface <网卡名> --noproxy '*' https://myip.ipip.net
#              ^^^^^^^ wwan0      ^^^^^^^^^^^ 两个都不能省
```

**① 必须绑【网卡名】，不能绑源 IP。** 实测对照（同一时刻、同一张卡）：

| 命令 | 结果 |
|---|---|
| `--interface wwan0 --noproxy '*'` | ✅ 成功 |
| `--interface <4G源IP> --noproxy '*'` | ❌ 超时 |

**② 必须 `--noproxy '*'`。** 本机若设了 `HTTP_PROXY`/`HTTPS_PROXY`/`all_proxy`，
curl 会去连**本地代理**，而源地址被绑成 4G → 连不到本机 → 失败。
**看着像 4G 不通，其实是自己没绕过代理。**

测通的话应看到运营商 IP（如 `223.104.148.12 中国 江苏 苏州 移动`）。

### IP 会变 ⇒ 策略路由必须动态重配 ⭐

**DHCP/QMI 每次重拨都换 IP**（实测见过 `10.67.120.102` → `10.83.106.229`
→ `10.76.14.137`）。旧规则指向已失效的源地址后，**症状就是"昨天还好好的，
今天又连不上了"**。所以别手工配一次了事：

```sh
sudo scripts/route_4g.sh --install-service     # 装成 systemd 服务，IP 一变自动重配
scripts/route_4g.sh --show                     # 看当前规则
sudo scripts/route_4g.sh --uninstall-service   # 卸载
```

它会生成并启用 `/etc/systemd/system/dji-4g-route.service`（`Restart=always`，
开机自启），内部跑 `route_4g.sh --watch`（`ip monitor address` 守地址变化）。
`route_4g.sh` 本身是幂等的 —— 每次重配都会先清掉旧规则再加新的，不会越积越多。

### 判定"能不能上网"的三层

不要只看 IP。拿到 `10.x` 私有地址**只证明 PDP 建立了，不证明能出网**：

1. `AT+CPIN?` → `READY`
2. `AT+CGATT?` → `1`，`AT+CEREG?` → `1`/`5`，`AT+CGACT?` → 含 `1`（PDP 已激活）
3. **实测 TCP 出网**：`curl --interface <源地址> --noproxy '*' https://myip.ipip.net`

两个**易误判**的点：
- **ICMP 常被运营商封禁** —— `ping` 不通但 `curl` 通是**正常的**，别用 ping 下结论。
- **首次请求可能超时**（运营商侧建链延迟）—— **要重试几次**再判定失败。

## 动手前的三条红线

1. **资费** —— 启用数据 = 真实计费的出口。**先确认套餐余量、是否漫游、漫游单价**。
   IoT/漫游卡的 APN 与消费级不同，**不要猜**，先读出来或问用户。

   > NetworkManager 里以太网 metric 默认低于 wifi，**4G 网卡一旦拿到带网关的 DHCP 租约，
   > NM 很可能把它设成默认路由**——用户没意识到时普通流量已经在走这张卡。
   > 动数据前先设：`nmcli con mod "<连接名>" ipv4.never-default yes ipv4.route-metric 1000`

2. **AT 写入类指令**（`AT+QCFG=...`、`AT+CGDCONT=`、`AT+CFUN=1,1` 等）能改网络注册、PDP、
   USB 模式和 SIM 状态，**切错可能"既上不了网也切不回来"**。只读指令随便发，
   写入类**先说清楚影响、拿到确认再发**。不要照搬来源不明的刷机/写卡命令。

3. **隐私** —— 共享日志/截图前抹掉 **EID、ICCID、IMSI、完整手机号、短信验证码**。
   `status.sh` 会提醒。

## 常用 AT 速查

| 指令 | 作用 | 类型 |
|---|---|---|
| `AT` / `ATI` | 握手 / 型号 | 只读 |
| `AT+CPIN?` | SIM 状态（`READY` 才有卡） | 只读 |
| `AT+CSQ` | 信号质量 | 只读 |
| `AT+CREG?` `AT+CEREG?` | 注册状态 | 只读 |
| `AT+CGATT?` | PS 附着 | 只读 |
| `AT+COPS?` | 当前运营商 | 只读 |
| `AT+QNWINFO` | 网络信息（LTE band 等） | 只读 |
| `AT+QCFG="usbnet"` | USB 模式（0=QMI/短信 1=ECM 2=MBIM 3=RNDIS） | 只读 |
| `AT+QCFG="usbcfg"` | 当前 VID/PID 与接口组合 | 只读 |
| `AT+CGDCONT?` | PDP/APN 配置 | 只读 |
| `AT+CGDCONT=1,"IP","<apn>"` | 设 APN | **写入** |
| `AT+QCFG="usbcfg",<vid>,<pid>,...` | 改 VID/PID（伪装） | **写入·NV** |
| `AT+CFUN=1,1` | 软重启模块 | **写入** |

## 文件地图

```
dji-4g-skill/
├── SKILL.md                      # 本文件：流程、模式选择、红线
├── scripts/
│   ├── preflight.sh              # 只读检测：USB/驱动/AT口/抢口进程
│   ├── bind_at.sh                # 绑 option 驱动出 /dev/ttyUSB*（需 root）
│   ├── at_tool.py                # AT 探针与读写（probe/read/write）
│   ├── disguise_ec25.py          # VID/PID 伪装与回滚（写入 NV）
│   ├── setup_vohive.sh           # 部署 vohive（下载/写配置/起服务）
│   ├── route_4g.sh               # 4G 源地址策略路由（--watch / --install-service 可自启）
│   └── status.sh                 # 只读诊断：模块在不在、模式、出口、能否出网
└── references/
    ├── troubleshooting.md        # 已验证故障与排查顺序
    └── vohive.md                 # vohive 配置字段、API、认证、常见报错
```

`packaging/` 下有两个 systemd 单元模板（`dji-4g-route.service`、
`vohive.service`）及各自的 `__占位符__` 替换说明 —— 既可一键安装，
也可当参考手改。

排查时：**先看 `scripts/status.sh` 输出，再按现象去 `references/troubleshooting.md` 找对应条目**。
需要 vohive 的配置/接口细节时读 `references/vohive.md`。

## 上游与出处

- 工具：`aresbit/vohive`（Go/Vue3，PolyForm Noncommercial 1.0.0，仅限非商业用途）。
  注意：release 二进制可能来自下游 fork 的构建（日志里的包路径会显示真实来源），
  下载后应先核对来源再运行。
- 伪装方法来源：`sdrpsps/vohive-oneclick` 附录 A（社区公开文档）。
- 硬件：佰旺 QDC507 / Quectel EG25-G，出厂 USB `2ca3:4006`。

本项目只做**个人学习/研究/测试**用途，请自行确保符合当地法律法规与运营商服务条款。
