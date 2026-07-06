# AIQA WebView

一个用于学习 iOS / macOS WebView 开发的简易浏览器项目。

它的核心目标不是做一个完整浏览器，而是提供一个**可以打开网页、执行固定 JavaScript、调用外部 API 并展示结果**的最小可用示例，方便继续迭代成你自己的工具型 App。

---

## 当前功能

### 浏览器能力
- 支持在 App 内打开网页
- 支持前进 / 后退 / 刷新
- 地址栏位于底部，界面更接近 Safari 风格
- 当前默认打开：
  - `https://m.u.ccb.com/#/login`

### JavaScript 执行能力
- 底部有一个 **JS 图标按钮**
- 点击后会在当前 `WKWebView` 页面里执行一段**固定脚本**
- 固定脚本会尝试提取：
  - 题目文本
  - 选项内容

### API 调用能力
提取成功后，会向下面这个接口发送请求：

- `POST https://aiqa.nuit-v6.stzze.cn/api/match-web`

请求体格式：

```json
{
  "question": "JS 提取到的结果"
}
```

### 结果展示能力
接口返回后，会用弹窗展示整理后的结果，包括：

- 是否匹配成功
- 匹配到的问题
- 题目类型
- 相似度
- 正常答案 / 乱序答案

其中：
- `success = 1` 表示匹配成功
- `success = 0` 表示匹配失败
- 如果 `remapped_answer` 不为空，优先展示它
- 否则展示 `answer`

另外还支持：
- 显示 / 隐藏原始 API 返回（默认关闭）
- 一键复制结果内容，方便调试

---

## 适用平台

当前项目保留了：
- **macOS**
- **iOS 18+**

也就是说：
- 你可以先在 Mac 上快速调试
- 也可以部署到 iOS 18 真机上运行

---

## 项目结构

```text
aiqa-webview/
├── aiqa-webview/
│   ├── aiqa_webviewApp.swift       # App 入口
│   ├── ContentView.swift           # 主界面（浏览器 UI / 结果弹窗）
│   ├── BrowserViewModel.swift      # WebView 状态、JS 执行、API 调用流程
│   ├── WebViewContainer.swift      # WKWebView 与 SwiftUI 的桥接层
│   ├── ExternalAPIClient.swift     # 外部 API 请求与结果整理
│   ├── ClipboardHelper.swift       # 跨平台复制工具
│   ├── aiqa-webview.entitlements   # macOS 网络权限配置
│   └── Assets.xcassets
├── aiqa-webview.xcodeproj/
└── README.md
```

---

## 关键实现说明

### 1. 为什么要有 `WebViewContainer`
`WKWebView` 不是原生 SwiftUI 视图，所以需要桥接：

- iOS：`UIViewRepresentable`
- macOS：`NSViewRepresentable`

这个桥接层就在：
- `aiqa-webview/WebViewContainer.swift`

### 2. 为什么 `WKWebView` 放在 `BrowserViewModel`
因为 `WKWebView` 有自己的状态：
- 当前页面
- 历史记录
- 页面上下文

如果每次 SwiftUI 刷新都重新创建 WebView，这些状态就会丢失。

所以项目里把它放在：
- `aiqa-webview/BrowserViewModel.swift`

### 3. 固定脚本如何工作
底部的 JS 按钮不会执行任意输入脚本，而是执行内置的题目提取脚本。

脚本会尝试查找类似下面这些页面结构：
- `.questions`
- `.questionBank .questions`
- `.title`
- `.answer li`

如果页面结构不符合预期，可能会返回：
- `未找到题目`
- `未找到题目标题容器`
- `未提取到题目标题文本`

### 4. API 返回如何处理
接口返回后，不直接把原始 JSON 暴露给用户，而是整理成更友好的展示内容。

相关逻辑在：
- `aiqa-webview/ExternalAPIClient.swift`

---

## 如何运行

### 在 macOS 上运行
1. 用 Xcode 打开项目
2. 运行目标选择 `My Mac`
3. 点击 Run

> 项目已经加入 macOS 网络访问权限，便于在 Mac 上调试 WebView。

### 在 iPhone 上运行
1. 用 Xcode 打开项目
2. 连接 iPhone
3. 在运行目标中选择你的手机
4. 在 `Signing & Capabilities` 中选择你的 Team
5. 点击 Run

要求：
- iOS 18+

---

## 如何使用

1. 启动 App
2. 浏览器默认会打开：
   - `https://m.u.ccb.com/#/login`
3. 进入你真正需要抓取题目的页面
4. 点击底部 **JS 图标按钮**
5. App 会：
   - 执行固定脚本
   - 提取题目与选项
   - 调用外部 API
   - 弹窗展示结果
6. 如需调试：
   - 打开“显示原始返回（调试用）”
   - 或点击“复制”把结果复制出去

---

## 已知限制

- 固定脚本依赖目标网页的 DOM 结构
- 如果网页结构变化，可能需要修改选择器
- 某些页面是动态渲染的，若 DOM 尚未出现，脚本可能抓不到内容
- 如果网页使用了 iframe、延迟渲染或更复杂的前端框架，可能还需要进一步增强脚本逻辑

---

## 后续可以继续优化的方向

- 等待目标 DOM 出现后再执行脚本
- 支持多套页面选择器
- 支持脚本配置化，而不是写死在代码里
- 支持多个 API 环境切换
- 把结果展示做得更像正式产品，而不是调试工具
- 增加历史记录 / 收藏 / 多标签页

---

## 学习重点建议

如果你是第一次接触 iOS / macOS 开发，建议重点看这几个文件：

1. `ContentView.swift`
   - 学 SwiftUI 布局
   - 学按钮事件怎么绑定到 ViewModel

2. `BrowserViewModel.swift`
   - 学 `ObservableObject`
   - 学如何持有 `WKWebView`
   - 学 JS 执行与状态更新

3. `WebViewContainer.swift`
   - 学 SwiftUI 和原生控件如何桥接

4. `ExternalAPIClient.swift`
   - 学 `URLSession`
   - 学 POST JSON 请求
   - 学如何把接口数据整理成用户友好的展示内容

---

## License

当前仓库未声明 License，如需开源，请自行补充。
