# Hax Shot AI

## 功能范围

Hax Shot 的 AI 功能用于分析当前截图选区，支持：

- 翻译截图；
- 解释截图；
- 深入理解截图；
- 普通文字追问；
- 图片拖拽和剪贴板输入；
- reasoning 思考过程、Markdown 流式输出、停止生成和推荐追问。

AI 会话只保存在当前截图进程内，不做历史会话持久化。

## 请求链路

```text
截图选区 + 矩形/箭头/文字标注
              ↓
ScreenshotExporter.renderPng()
              ↓
AiImageAttachment(image/png)
              ↓
HaxAiController
              ↓
plume_ai_chat
              ↓
DeepSeek SSE
```

AI 必须使用 `ScreenshotExporter` 的最终 PNG，不能重新截图、绕过标注或单独裁剪原图。

## 代码结构

```text
lib/features/ai/
├── controllers/hax_ai_controller.dart
├── models/
├── services/
└── views/
    ├── ai_page.dart
    └── widgets/
```

通用对话能力位于：

```text
packages/plume_ai_chat/
```

该 package 负责会话历史、HTTP/SSE、reasoning、流式预览、Stop、follow-up suggestions 和通用消息模型。Hax Shot 不应再实现第二套 AI 请求或流式状态管理。

## 截图 Action

新的截图 Action 会创建新的视觉会话：

```text
Translate / Explain / Deep Understand
              ↓
清空旧会话
              ↓
发送当前最终 PNG + Action Prompt
```

同一轮会话中的普通追问只发送文字，不重复上传截图。

## API Key

API Key 由 Hax Shot Host 使用 `shared_preferences` 保存：

```text
hax_shot.deepseek_api_key
```

`plume_ai_chat` 不负责保存凭据，只从 Host 提供的 callback 读取 API Key。

## AI 窗口

AI 页面复用截图子进程，不创建第二个原生窗口。标题栏支持拖动窗口，关闭按钮结束当前截图进程。AI 侧栏尺寸、输入框和消息列表遵循 Plume AI Chat 的布局结构。

## 本地验证

```bash
fvm flutter analyze
fvm flutter test
cd packages/plume_ai_chat
fvm flutter test
```

真实请求验证需要在设置页配置 DeepSeek API Key。网络请求最长等待 60 秒；用户可以通过输入框 Stop 取消当前生成。
