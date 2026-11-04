# XHSRuntimeBridge

面向 TrollStore/重签注入场景的独立 iOS 动态库。第一版只做运行观察：

- 启动后向 Windows collector 发送 `dylib_loaded`；
- 枚举笔记详情相关 Selector 的实际所属类和类型编码；
- 观察经过 `NSURLSession` 的 `/api/sns/v10/note` 请求；
- 包装 completion，记录状态码、响应长度和 JSON 顶层结构；
- 所有事件同时备份到 App 的
  `Documents/XHSRuntimeBridge/events.ndjson`。

它不会记录请求头、Cookie、SID、签名值或完整 `xsec_token`。

## TrollStore 注入

本工程产物是独立 dylib，不要求修改小红书可执行文件的代码或重新签名 IPA。
使用你的 TrollStore dylib 注入工具，将：

```text
XHSRuntimeBridge.dylib
```

注入已安装的小红书，然后强制结束小红书进程并重新启动。

小红书 9.15.1 自带 `NSLocalNetworkUsageDescription`，且 ATS 配置中
`NSAllowsArbitraryLoads=true`，所以这一版本不需要为了局域网日志连接修改
`Info.plist`。

## 在小红书内配置接收地址

不需要通过 Apple Devices/iTunes 写配置文件。dylib 加载后，小红书右下角会
出现一个半透明的 `⚙` 按钮。

点击后在 App 内填写：

```text
Collector URL: http://172.18.177.3:8901/events
Collector Token: 可选；Windows 未设置 XHS_LOG_TOKEN 时可以留空
```

可以只填写 `172.18.177.3:8901`，插件会自动补全为：

```text
http://172.18.177.3:8901/events
```

点击“保存”后，地址和 Token 保存在小红书自身的 `NSUserDefaults` 中；
下次启动无需再次填写。当前默认地址也是
`http://172.18.177.3:8901/events`。

按钮颜色和文字表示状态：

```text
绿色 ⚙ = 日志推送已开启
红色 ⏸ = 日志推送已停止
```

进入设置后可以点击“开始推送”或“停止推送”切换状态。

手机和电脑必须能够互访，Windows 防火墙需要允许 collector 端口入站。
明文 HTTP 仅建议用于可信隔离局域网中的临时调试，长期使用建议 HTTPS。

高级用法仍可在 `Info.plist` 中提供 `XHSRuntimeCollector*` 默认值，但
TrollStore 注入场景不需要这么做。

## 构建

工程使用 Theos。macOS 或支持 iOS toolchain 的构建环境中：

```bash
export THEOS=/path/to/theos
make clean package
```

产物位于：

```text
.theos/obj/debug/XHSRuntimeBridge.dylib
```

没有 Mac 时，可以在私有 GitHub 仓库中使用附带的 Actions 工作流构建。
不要把包含 collector token、签名证书或重签后的 IPA 上传到公开仓库。

## 当前覆盖边界

`NSURLSession` Hook 只会看到经过该 API 的请求。如果小红书详情请求使用
Cronet 或其他自定义传输层，仍然会收到 `selector_discovered`，但未必收到
`note_detail_request`。届时根据实际发现的类名和类型编码，第二阶段再对
`requestNoteDetail:completion:` 等业务方法做精确 Hook。

第一阶段不要盲目替换这些业务方法：它们可能是 Swift 方法或拥有不同参数
布局，必须先用 `type_encoding` 确认 ABI。
