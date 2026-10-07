# vohive 操作要点

上游：`aresbit/vohive`（Go + Vue3，PolyForm Noncommercial 1.0.0，**仅限非商业用途**）。
部署我们通常用 release 二进制（Makefile 走 `upx --best --lzma`，所以二进制是 UPX 压缩的，
`go version -m` 读不出构建信息 —— 这是正常的，不代表文件有问题）。

## 目录布局

```
<dir>/
├── vohive              # 二进制
├── config/config.yaml  # 必需，缺了会启动失败
├── data/               # vohive.db (SQLite)
└── logs/
```

需要访问 `/dev/ttyUSB*`，所以**以 root 运行**。

## config.yaml 最小可用配置

```yaml
server:
    debug: false
    port: 7575

web:
    username: admin
    password: admin123        # ← 改掉！默认监听所有网卡

devices:
    - device_backend: at
      id: dji-4g-1
      name: "DJI 4G (QDC507)"
      modem_imei: "866069050458254"    # ← 必须！vohive 靠 IMEI 认设备

# 通知渠道，不用就关
telegram: {enabled: false}
feishu:   {enabled: false}
qq:       {enabled: false}
webhook:  {enabled: false}
bark:     {enabled: false}
email:    {enabled: false}
pushplus: {enabled: false}
```

### 设备字段的坑

`DeviceConfig`（`internal/config/config.go`）里这几个字段
**全部是 `mapstructure:"-"`**，即**从来不从文件读取**：

| 字段 | 说明 |
|---|---|
| `at_port` | 注释：*Deprecated: 运行时解析;AT 终端用 Worker.ResolvedATPort()* |
| `usb_path` | 注释：*Deprecated: 运行时按 IMEI 现解析,绝不从文件读取* |
| `interface` / `manage_port` / `qmi_device` / `control_device` | 同上 |

**所以指定路径是没用的，只能靠 `modem_imei` 绑定。**
写了路径而没写 IMEI，报错就是
`未找到匹配的非 QMI 硬件（AT-only 或 MBIM），跳过启动`。

### 后端（`device_backend`）可选值

只有三个：**`at` / `qmi` / `mbim`**（源码 `internal/backend/factory.go`）。
**没有 `ecm`** —— 空值/非法值都归一到 `at`。

- `at`：走 `/dev/ttyUSB*`。我们的场景（ECM 组合）用这个。
- `qmi`：需要 `/dev/cdc-wdm0`（模块在 QMI 模式时才有）。
- `mbim`：需要 MBIM 接口。

### 设备识别还受 VID 白名单限制

`internal/device/discovery_compat.go`：

```go
if vid != 0x2c7c && vid != 0x05c6 {
    return CompatibleModem{}, false
}
```

只认 Quectel / Qualcomm。厂商定制模块（如大疆 `0x2ca3`）必须先伪装 VID/PID。

## 起停与日志

```sh
cd <dir> && sudo nohup ./vohive > logs/run.log 2>&1 &
tail -f logs/run.log
```

启动日志里 `[GIN-debug]` 是路由表（不是错误）。关注这几行：

```
[<id>] AT 管理器已启动 {"port": "/dev/ttyUSB2"}
[<id>] 设备冷启动预热完毕
[<id>] 设备 SIM 身份已同步到数据库 {"imei":"...","iccid":"...","backend":"at"}
```

## API

**认证**：先登录拿 token，再用 Bearer 头（cookie 不生效）。

```sh
TOKEN=$(curl -s -X POST http://127.0.0.1:7575/api/auth/login \
        -H 'Content-Type: application/json' \
        -d '{"username":"admin","password":"admin123"}' \
        | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")

curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7575/api/devices
```

常用端点：

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/api/auth/login` | 拿 token |
| GET | `/api/devices` | 设备列表 + 状态 |
| GET | `/api/devices/discovered` | 已发现但未纳管的硬件 |
| GET | `/api/devices/:id/overview` | 单设备概览（含 `.../overview/stream` SSE 流） |
| GET | `/api/devices/:id/status` | 详细状态 |
| GET | `/api/devices/:id/config` | 设备配置 |
| GET | `/api/devices/:id/actions/at/history` | AT 历史 |
| GET | `/api/logs/stream` | 日志流 |
| GET | `/api/devices/:id/esim*` | eSIM（`profiles` / `chip-info` / `eids` / `actions/switch`） |

### `GET /api/devices` 返回的关键字段

```json
{
  "id": "dji-4g-1",
  "lifecycle_phase": "online",     // 目标状态
  "running": true, "healthy": true,
  "control_online": true, "physical_present": true, "worker_running": true,
  "data_connected": false,         // 上网是否已建立
  "radio_registered": true,        // 已注册运营商
  "sms_enabled": true,
  "network_enabled": false,
  "interface": "enx7ad49d4ad4de",
  "esim_transport": "at",
  "modem": {
    "operator": "中国移动", "network_mode": "LTE",
    "radio_band": "LTE BAND 40", "signal_dbm": -53,
    "reg_status": 1, "ps_attached": false
  },
  "local_phone": "+8615810985829"
}
```

判读：`lifecycle_phase == "online"` 且 `healthy == true` 表示纳管成功。
`data_connected` / `network_enabled` 是**上网**能力，与纳管是两回事。

## 常见启动报错

| 报错 | 原因 |
|---|---|
| `初始化配置管理器失败: ... open config/config.yaml` | 没有 config 文件 |
| `未找到匹配的非 QMI 硬件（AT-only 或 MBIM），跳过启动` | VID 不在白名单（#6）或没写 `modem_imei`（#7） |
| `启动期 SIMAuth 逻辑通道清理失败 ... ERROR` | **无害**，启动期清理残留逻辑通道的噪音 |
| `无法同步设备信息：IMEI 为空` | 冷启动早期还没读到 IMEI，通常随后自动补齐 |
| 401 `unauthorized` | 没用 Bearer token（cookie 不行） |

## 安全

- WebUI **默认监听 `*:7575`**（全网卡，局域网可达）+ 默认密码 `admin123`。
  建议改密码，或让它只监听 `127.0.0.1`。
- 想长期运行要做 systemd 服务；`nohup` 起的进程重启即失效，
  放在 `/tmp` 还会被系统清理。
