# NoteDetailMonitor

独立的 Theos Logos dylib，只观察 `com.xingin.discover` 的帖子详情跳转，
不修改页面业务逻辑，也不记录 Cookie、SID、Authorization 或其他会话秘密。

## 当前功能

- Hook `UINavigationController` 的 push；
- Hook `UIViewController` 的 present 和 viewDidAppear；
- 初步识别详情控制器；
- 只读取白名单业务字段：`noteId`、`userId`、`source`、`feedId`、
  `routerParams` 等；
- 无法读取时输出 JSON `null`，不根据页面文本猜测 ID；
- 本地保存 JSONL，并 POST 到已有的 Windows collector；
- 默认 collector：
  `http://172.18.177.3:8901/events`。

第一版使用控制器/对象公开可观察的 Getter；真正的类名和字段应以运行时
日志为准，候选名称不代表字段一定存在。

## 构建

```bash
export THEOS=/path/to/theos
make clean package
```

工程使用 Bundle ID：

```text
com.xingin.discover
```

如果注入工具要求 Framework，可把生成的 dylib 放入一个 Framework 包，
或使用仓库根工作流生成的注入包。

## 事件

```json
{
  "event": "note_detail_candidate",
  "navigation": "push",
  "controller": "实际控制器名",
  "note_id": "...",
  "user_id": "...",
  "source": null
}
```
