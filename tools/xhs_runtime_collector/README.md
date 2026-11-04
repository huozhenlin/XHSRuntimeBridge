# XHS Runtime Collector

Windows 上运行的结构化运行日志接收器。它只负责接收注入模块主动
`POST` 的事件，不负责注入、抓包或绕过 TLS。

## 启动

```powershell
$env:XHS_LOG_TOKEN = "请替换为随机长字符串"
python .\tools\xhs_runtime_collector\collector.py `
  --host 0.0.0.0 `
  --port 8901
```

检查服务：

```powershell
Invoke-RestMethod http://127.0.0.1:17321/health
```

首次使用需要在 Windows 防火墙中允许 Python 接收入站连接。手机和
电脑需要能够互相访问；手机端配置使用电脑的局域网 IPv4 地址，而不是
`127.0.0.1`。

## 事件协议

请求：

```http
POST /events
Authorization: Bearer <XHS_LOG_TOKEN>（可选）
Content-Type: application/json
```

如果 Windows 没有设置 `XHS_LOG_TOKEN`，接收器不会要求
`Authorization`，手机端 Token 可以留空。

单条事件：

```json
{
  "event": "method_enter",
  "time": 1793760000000,
  "class": "ExampleClass",
  "selector": "exampleMethod:",
  "thread": "main",
  "data": {
    "argument_types": ["NSString"]
  }
}
```

也支持最多 200 条事件组成的 JSON 数组。服务会自动遮盖 Cookie、SID、
Authorization、token、设备 ID 等常见敏感字段，然后写入：

```text
tools/xhs_runtime_collector/data/events-YYYY-MM-DD.ndjson
```

查看内存中的最近事件：

```powershell
$headers = @{ Authorization = "Bearer $env:XHS_LOG_TOKEN" }
Invoke-RestMethod `
  -Headers $headers `
  "http://127.0.0.1:17321/events/recent?limit=100"
```

## 推荐事件

先只发送控制流和类型信息，不要发送账号凭证或完整请求头：

```text
dylib_loaded
selector_discovered
method_enter
method_exit
note_detail_request
note_detail_response
note_model_received
logger_error
```

`note_detail_response` 初期建议只记录响应大小、顶层字段名和对象类型。
确认采集范围合适后，再对白名单接口记录经过脱敏的业务字段。

## iOS/TrollStore 配置注意事项

小红书 9.15.1 本身已经声明本地网络用途、允许对应网络访问，所以 TrollStore
注入场景不要求重新签名或修改 `Info.plist`。注入 dylib 后，直接在小红书
右下角的 `⚙` 按钮内配置电脑 IP 和 token；它们会存入 App 自身的
`NSUserDefaults`。

更安全的长期方案是 HTTPS；明文 HTTP 仅建议用于可信隔离局域网中的短期调试。
