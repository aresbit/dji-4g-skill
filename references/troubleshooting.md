# 故障排查（全部为实测验证过的现象）

排查顺序：**先跑 `scripts/preflight.sh` / `scripts/status.sh`**，再按现象对号入座。

---

## #1 未检测到模块 —— 但模块绿灯是亮的 ⭐ 最常见

**现象**：`lsusb` 里没有 `2ca3:4006`；`/dev/ttyUSB*` 不存在；
内核日志里查不到任何该设备的记录。但模块上的 LED 是亮的。

**根因**：用了一根 **只供电、不接数据脚** 的 USB-C 充电线。
电源脚接通 → LED 亮；D+/D- 没接 → 电脑永远看不见它。

**判定**（30 秒）：拿这根线去接个手机或 U 盘：
- 电脑认出来了 → 线没问题，查模块/端口
- 电脑只充电、没反应 → **就是线的问题**

**解决**：换一根明确标注"数据传输"的 USB-C 线。

**验证方法**（不换线也能确认是线的问题）：开一个监听，然后拔插模块：

```sh
udevadm monitor --udev --subsystem-match=usb
```

如果拔插期间**一条事件都没有**，而同一台机器的日志能正常记录其他 USB 设备插拔，
那就是物理层问题 —— 软件层面无解。

> **关键概念**：对 4G 上网模块来说，"通电"和"能被电脑使用"是两回事。
> 绿灯只证明前者。

---

## #2 AT 指令返回【空】而不是报错 —— ModemManager 抢串口

**现象**：刚测过 `AT` 能回 `OK`，但接着发一串查询指令全部返回空；
或者手工 AT 一直读不到东西。

**根因**：**ModemManager** 会主动探测并独占 AT 口（`lsof /dev/ttyUSB3` 能看到它）。
它在跑的时候会和你的读取互相吃掉数据 —— **表现为空响应，不报错**，
这个症状极易误判成"模块坏了"或"AT 口不对"。

**确认**：

```sh
systemctl is-active ModemManager
sudo lsof /dev/ttyUSB3        # 看是不是 ModemManager 占着
mmcli -L                      # MM 是否已识别到模块
```

**解决**：

```sh
sudo systemctl stop ModemManager
```

用 vohive 之前**必须**停它（vohive 要独占 AT 口）。

> 反过来说：MM 独占串口时，**让 MM 自己报状态**反而是最省事的读法
> （`mmcli -m 0 -K`），因为它持有独占权。

---

## #3 串口不回 AT

两个原因，都要排查：

1. **没拉 DTR/RTS**。打开串口时必须显式置高，否则模块不回话：
   ```python
   s = serial.Serial(port, 115200, timeout=1.5)
   s.dtr = True; s.rts = True
   ```
   `scripts/at_tool.py` 已处理。

2. **AT 口不一定是 ttyUSB2**。文档和教程普遍写 ttyUSB2，但**实测为准**
   （本机实际是 `ttyUSB3`）。用 `scripts/at_tool.py probe` 逐口试。

---

## #4 有 192.168.225.x 但上不了网

**现象**：模块网关 `192.168.225.1` 能 ping 通（约 2ms），但公网不通。

**根因**：拿到 `192.168.225.x` **只证明模块自己的 DHCP/链路在工作，
不证明它附着上了运营商**。数据要通过，模块侧必须有 PDP 上下文 ——
而 PDP 需要 **APN**，模块出厂常常**没有预置 APN**。

**排查三层，缺一不可**：

```sh
sudo scripts/at_tool.py probe     # 看 CPIN / CEREG / CGATT
```

1. `AT+CPIN?` → 必须是 `READY`
2. `AT+CEREG?` → `1`(本网) 或 `5`(漫游)；`AT+CGATT?` → `1`
3. **实测出网**（绑源地址，绕过本机代理）：
   ```sh
   curl --interface 192.168.225.2 https://myip.ipip.net
   ```

**写 APN**（写入类指令，先确认资费）：

```sh
sudo scripts/at_tool.py write 'AT+CGDCONT=1,"IP","cmnet"'
```

> **不要猜 APN**。IoT/行业卡与消费级不同（移动 `cnet` vs `cmiot`）。
> 先读 `AT+CGDCONT?` 看有没有现成的，或问用户。

---

## #5 流量被悄悄走掉 / 默认路由被 4G 抢走 ⚠️ 涉及钱

**现象**：4G 网卡接上后，普通上网开始计费，用户没意识到。

**根因**：NetworkManager 里**以太网的 metric 默认低于 wifi**，
所以 4G 网卡一旦拿到带网关的 DHCP 租约，NM 很可能把它设成**默认路由**。

**确认**：

```sh
ip route show default
# 若 dev 是 enx.../wwan... 而不是 wlp... → 流量正在走 SIM
```

**预防**（动数据之前先设）：

```sh
nmcli con mod "<连接名>" ipv4.never-default yes ipv4.route-metric 1000
nmcli con up "<连接名>"
```

这样网卡能拿 IP，但**永远不抢默认路由**；需要走它时用
`curl --interface <IP>` 或单独加一条策略路由。

---

## #6 vohive 报 `未找到匹配的非 QMI 硬件（AT-only 或 MBIM），跳过启动`

两个独立原因，都要查：

**(a) VID 不在白名单**。vohive 源码 `internal/device/discovery_compat.go`：

```go
if vid != 0x2c7c && vid != 0x05c6 {
    return CompatibleModem{}, false
}
```

只认 Quectel(`0x2c7c`) / Qualcomm(`0x05c6`)。
大疆出厂 `0x2ca3` 被**硬拒** → 必须伪装成 EC25：

```sh
sudo scripts/disguise_ec25.py --apply
```

**(b) config 里没写 `modem_imei`**。见 #7。

> 另一个表现：vohive 日志里的包路径若显示成别的 fork（例
> `github.com/<someone>/vohive/...`），说明这个二进制是**下游 fork 构建的**。
> 能用，但来源要心里有数。

---

## #7 config 里写了 `at_port` / `interface` 但不生效

**根因**：`DeviceConfig` 里这些字段的 tag 是 `mapstructure:"-"`，
注释写着 **"Deprecated: 运行时按 IMEI 现解析，绝不从文件读取"**。

也就是说 **vohive 只认 IMEI 来绑定设备**，路径类字段一律运行时解析。

**解决**：config 里给设备写 `modem_imei`，其他别写：

```yaml
devices:
    - device_backend: at
      id: dji-4g-1
      name: "DJI 4G (QDC507)"
      modem_imei: "866069050458254"
```

取 IMEI：`sudo scripts/at_tool.py read 'AT+CGSN'`

---

## #8 ECM 网卡拿不到 DHCP 地址

**现象**：网卡 UP、载波正常（`ethtool` 显示 Link detected: yes），
但 NetworkManager 报 `IP 配置无法保留（无可用地址、超时等）`，45 秒后失败。

**根因**：EG25-G 在 ECM 模式下的 DHCP 服务不一定响应（尤其 MM 在管的时候）。

**解决**：静态配地址即可，链路本身是好的：

```sh
sudo ip addr add 192.168.225.2/24 dev enx<mac>
ping -c2 192.168.225.1      # 模块自身，应秒回
```

---

## #8b 「vohive 说连上了，但 curl 超时」—— 缺策略路由 ⭐ 最隐蔽

**现象**：vohive API 返回 `网络已启动`、`network_connected: true`、
还给了 `public_ip`；`wwan0` 也有 IP。但

```sh
curl --interface <4G源地址> https://myip.ipip.net     # 超时
```

**根因**：**Linux 路由查找只看 metric，不看源地址属于哪张网卡。**
双默认路由时 wifi（metric 600）永远胜过 4G（metric 5000）：

```sh
ip route get 1.1.1.1 from <4G源地址>
#  →  via 192.168.3.1 dev wlp18s0      ← 4G 的源包从 wifi 出去了
```

源地址不属于 wifi → 包被丢弃。

**解决**：

```sh
sudo scripts/route_4g.sh
# 等价于：
#   ip route replace default via <GW> dev wwan0 table 200
#   ip rule add from <4G源地址> lookup 200 priority 100
```

**验证**：`ip route get 1.1.1.1 from <源地址>` 应显示 `dev wwan0 ... table 200`。

---

## #8c 「4G 不通」其实是没绕过代理 / 绑错了对象 ⭐ 最容易被自己骗

**现象**：用 curl 测 4G 出网总是超时或报错，
错误里可能出现 `Trying 127.0.0.1:<port>` / `Could not resolve proxy`。

**两个独立原因，实测对照（同一时刻、同一张卡）：**

| 命令 | 结果 |
|---|---|
| `curl --interface wwan0 --noproxy '*' https://myip.ipip.net` | ✅ 成功 |
| `curl --interface wwan0 https://myip.ipip.net`（代理在） | ❌ 走了本地代理 |
| `curl --interface <4G源IP> --noproxy '*' …` | ❌ 超时 |

**根因 ①：代理**。本机设了 `HTTP_PROXY`/`HTTPS_PROXY`/`all_proxy` 时，
curl 会去连**本地代理**，而源地址被绑成 4G 网卡 → 连不到本机。

**根因 ②：绑错对象**。必须绑**网卡名**（`wwan0`），
**不要绑源 IP** —— 实测绑 IP 会失败，哪怕策略路由完全正确。

**正确写法**：

```sh
curl -s --interface <网卡名> --noproxy '*' https://myip.ipip.net
```

（若想彻底排除代理干扰，可再清空环境：`env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY curl …`）

---

## #8c2 昨天还好好的，今天又连不上 —— 策略路由指向了旧 IP ⭐

**现象**：配好能用，过一段时间（或重拨后）又不行了，路由"看起来"还在。

**根因**：**DHCP/QMI 每次重拨都换 IP**。实测同一张卡见过
`10.67.120.102` → `10.83.106.229` → `10.76.14.137`。
旧的 `ip rule from <旧IP>` 不会自动跟随，新 IP 的包就落回主表走 wifi 被丢。

**解决**：别手工配一次了事，装成服务让它自动跟随：

```sh
sudo scripts/route_4g.sh --install-service     # /etc/systemd/system/dji-4g-route.service
scripts/route_4g.sh --show                     # 检查当前规则是否指向当前 IP
```

`route_4g.sh` 是幂等的：每次重配先清掉旧规则再加新的。

**自查**：`ip rule show | grep 'lookup 200'` 里的源地址
必须等于 `ip -br addr show wwan0` 的当前 IP。

---

## #8c3 模块自己也出不去 —— 就是卡侧问题，别再折腾主机

**判据**（决定性的，能一刀切开主机问题 vs SIM/运营商问题）：

```sh
# 让模块自己 ping（不走主机协议栈）
scripts/at_tool.py --port <AT口> read 'AT+QPING=1,"223.5.5.5",4,8'
# 结果通过异步 URC 返回：+QPING: <err>
#   0   = 成功
#   569 = 通用失败
```

**若 `+QPING` 失败而主机侧一切正常（注册、PDP、路由都对）→
问题在 SIM/运营商，主机侧无解。**

优先怀疑：**欠费/停机**（见 #8d）、数据业务未开通、定向卡/物联卡需专用 APN。

---

## #8d 欠费/停机：PDP 能激活，但数据不通

**现象**：`AT+CGACT=1,1` 返回 `OK`，`AT+CGPADDR=1` 也给了地址，
但没有任何数据能通过；QMI 侧报 `call end type=2 code=241`。

**根因**：SIM 欠费/停机。**注册和 PDP 激活不消耗余额，实际传输才消耗** ——
所以链路看起来"正常"，数据却全部被丢。

**解决**：充值后**必须重建 PDP**，旧的上下文不会自动生效：

```sh
# 最干净：重置模块
scripts/at_tool.py write 'AT+CFUN=1,1'
# 等重新枚举后，重新建立数据连接（vohive: PATCH network，或 AT+CGACT=1,1）
```

> 判据：重建后 `AT+CGPADDR=1` 会给出**与之前不同**的地址，才是真的重协商了。

---

## #8e PDP 已被激活时，QMI "Start Network" 会冲突

**现象**：先用 AT `AT+CGACT=1,1` 激活了 PDP，再让 vohive（QMI）启动数据网络，
报 `QMI error: service=0x01 msg=0x0020 ... call end type=2 code=241`。

**根因**：QMI 的 Start Network Interface 发现数据调用已存在，报冲突。

**解决**：让**一方**独占数据控制权。用 vohive/QMI 时，先取消 AT 层的 PDP：

```sh
scripts/at_tool.py write 'AT+CGACT=0,1'      # 再让 vohive 启动
```

反过来，**纯 QMI 模式下 `AT+CGACT` 会返回 ERROR**（QMI 持有控制权），
这是正常的，不要误判成模块故障。

---

## #9 `ping` 不通，但网页能开 —— 不是故障

**现象**：`ping 223.5.5.5` / `8.8.8.8` 100% 丢包，但 `curl` 返回正常。
连**模块自己的网关** `10.x.x.101` 都 ping 不通。

**根因**：**运营商常封禁 ICMP**。

**结论**：判定"能不能上网"**必须用 TCP**（curl），
**不能用 ping 下结论**。这是最容易误判的一条。

**另一个相关的误判**：首次请求可能**因运营商侧建链延迟而超时** ——
要**重试 2–3 次**再判定失败。实测同一配置下第 1 次超时、第 2/3 次即成功。

---

## 附：USB 模式会随 `usbnet` 改变

| `AT+QCFG="usbnet"` | 模式 | Linux 上出现 | 说明 |
|---|---|---|---|
| 0 | QMI | `/dev/cdc-wdm0` + `wwan0` | vohive 默认后端最省事 |
| 1 | ECM | `enx<mac>` 网卡 | 免驱，本 skill 默认场景 |
| 2 | MBIM | `wwan0`（MBIM） | vohive 支持 |
| 3 | RNDIS | `usb<mac>` | Windows 友好 |

**改完必须重启模块**（`AT+CFUN=1,1`）才生效，且会重新枚举，
AT 口名字可能变化 —— 要重新 probe。
