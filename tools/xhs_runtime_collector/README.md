# XHS Runtime Collector

Windows 涓婅繍琛岀殑缁撴瀯鍖栬繍琛屾棩蹇楁帴鏀跺櫒銆傚畠鍙礋璐ｆ帴鏀舵敞鍏ユā鍧椾富鍔?`POST` 鐨勪簨浠讹紝涓嶈礋璐ｆ敞鍏ャ€佹姄鍖呮垨缁曡繃 TLS銆?
## 鍚姩

```powershell
$env:XHS_LOG_TOKEN = "璇锋浛鎹负闅忔満闀垮瓧绗︿覆"
python .\tools\xhs_runtime_collector\collector.py `
  --host 0.0.0.0 `
  --port 8901
```

妫€鏌ユ湇鍔★細

```powershell
Invoke-RestMethod http://127.0.0.1:17321/health
```

棣栨浣跨敤闇€瑕佸湪 Windows 闃茬伀澧欎腑鍏佽 Python 鎺ユ敹鍏ョ珯杩炴帴銆傛墜鏈哄拰
鐢佃剳闇€瑕佽兘澶熶簰鐩歌闂紱鎵嬫満绔厤缃娇鐢ㄧ數鑴戠殑灞€鍩熺綉 IPv4 鍦板潃锛岃€屼笉鏄?`127.0.0.1`銆?
## 浜嬩欢鍗忚

璇锋眰锛?
```http
POST /events
Authorization: Bearer <XHS_LOG_TOKEN>锛堝彲閫夛級
Content-Type: application/json
```

濡傛灉 Windows 娌℃湁璁剧疆 `XHS_LOG_TOKEN`锛屾帴鏀跺櫒涓嶄細瑕佹眰
`Authorization`锛屾墜鏈虹 Token 鍙互鐣欑┖銆?
鍗曟潯浜嬩欢锛?
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

涔熸敮鎸佹渶澶?200 鏉′簨浠剁粍鎴愮殑 JSON 鏁扮粍銆傛湇鍔′細鑷姩閬洊 Cookie銆丼ID銆?Authorization銆乼oken銆佽澶?ID 绛夊父瑙佹晱鎰熷瓧娈碉紝鐒跺悗鍐欏叆锛?
```text
tools/xhs_runtime_collector/data/events-YYYY-MM-DD.ndjson
```

鏌ョ湅鍐呭瓨涓殑鏈€杩戜簨浠讹細

```powershell
$headers = @{ Authorization = "Bearer $env:XHS_LOG_TOKEN" }
Invoke-RestMethod `
  -Headers $headers `
  "http://127.0.0.1:17321/events/recent?limit=100"
```

## 鍙戦€佹墦寮€璇︽儏鍛戒护

鎵嬫満绔細涓诲姩杞鍛戒护锛屽洜姝?Windows 涓嶉渶瑕佺洿鎺ヨ繛鎺?iPhone锛?
```powershell
$body = @{
  command = "open_note"
  note_id = "6ae4132f000000000300bbb2"
  request_id = "manual-001"
  strategy = "auto"
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri "http://127.0.0.1:8901/commands/enqueue" `
  -ContentType "application/json" `
  -Body $body
```

娉ㄥ叆妯″潡闅忓悗浼氫粠锛?
```text
GET /commands/next
```

鍙栧嚭鍛戒护锛屽湪灏忕孩涔︿富绾跨▼璋冪敤宸茶瀵熷埌鐨勮鎯呰矾鐢便€傝鎯呴〉鍔犺浇瀹屾垚鍚庯紝
`note_detail_open` 浜嬩欢浼氬甫鍥炲悓涓€涓?`request_id`銆?
## 鎺ㄨ崘浜嬩欢

鍏堝彧鍙戦€佹帶鍒舵祦鍜岀被鍨嬩俊鎭紝涓嶈鍙戦€佽处鍙峰嚟璇佹垨瀹屾暣璇锋眰澶达細

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

`note_detail_response` 鍒濇湡寤鸿鍙褰曞搷搴斿ぇ灏忋€侀《灞傚瓧娈靛悕鍜屽璞＄被鍨嬨€?纭閲囬泦鑼冨洿鍚堥€傚悗锛屽啀瀵圭櫧鍚嶅崟鎺ュ彛璁板綍缁忚繃鑴辨晱鐨勪笟鍔″瓧娈点€?
## iOS/TrollStore 閰嶇疆娉ㄦ剰浜嬮」

灏忕孩涔?9.15.1 鏈韩宸茬粡澹版槑鏈湴缃戠粶鐢ㄩ€斻€佸厑璁稿搴旂綉缁滆闂紝鎵€浠?TrollStore
娉ㄥ叆鍦烘櫙涓嶈姹傞噸鏂扮鍚嶆垨淇敼 `Info.plist`銆傛敞鍏?dylib 鍚庯紝鐩存帴鍦ㄥ皬绾功
鍙充笅瑙掔殑 `鈿檂 鎸夐挳鍐呴厤缃數鑴?IP 鍜?token锛涘畠浠細瀛樺叆 App 鑷韩鐨?`NSUserDefaults`銆?
鏇村畨鍏ㄧ殑闀挎湡鏂规鏄?HTTPS锛涙槑鏂?HTTP 浠呭缓璁敤浜庡彲淇￠殧绂诲眬鍩熺綉涓殑鐭湡璋冭瘯銆?
## Active fetch without opening the UI

Use `fetch_note` when the goal is to make the app request a note with its own
logged-in session and push a bounded response snapshot to `POST /events`,
without navigating to the detail page:

```powershell
$body = @{
  command = "fetch_note"
  note_id = "6ae4132f000000000300bbb2"
  request_id = "fetch-001"
  strategy = "fetch_only"
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri "http://127.0.0.1:8901/commands/enqueue" `
  -ContentType "application/json" `
  -Body $body
```

Watch for `note_detail_request_started`, `note_detail_network_result`, and
`note_detail_fetch_completed`. `open_note` keeps the original behavior: fetch,
then attempt to open the detail page. Sensitive session fields are not intended
to be collected.

## Deep-link active mode

For normal UI-driven active lookup, use the app's own route instead of calling
its private network executor directly:

```powershell
$body = @{
  command = "open_note"
  note_id = "6ae3f862000000001200f174"
  type = "normal"
  request_id = "scheme-001"
  strategy = "deep_link"
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri "http://172.18.177.3:8901/commands/enqueue" `
  -ContentType "application/json" `
  -Body $body
```

The injected module requests only the constrained form
`xhsdiscover://item/<note_id>?type=normal` or `type=video`; it does not accept
arbitrary URLs from the command queue. The app then performs its normal detail
loading flow, and the existing passive model hooks return the parsed model and
media fields.

Use `strategy = "auto"` to use the deep link path by default. Use
`strategy = "xy_note_api"` to force the previous direct request path.

\n