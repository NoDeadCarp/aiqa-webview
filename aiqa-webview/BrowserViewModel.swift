import Combine
import Foundation
import WebKit

/// 浏览器页面的状态与行为都集中放在这个 ViewModel 里。
///
/// 这样做对初学者有两个好处：
/// 1. SwiftUI 视图只专注于“显示什么”和“按钮点了做什么”。
/// 2. `WKWebView` 这种有生命周期的对象可以稳定地保存在同一个地方，
///    不会因为 SwiftUI 视图刷新而被重复创建。
@MainActor
final class BrowserViewModel: NSObject, ObservableObject {
    /// 地址栏当前显示的内容。
    @Published var addressText = "https://m.u.ccb.com/#/login"

    /// JavaScript 输入框的默认示例。
    @Published var javaScriptText = "document.title"

    /// JavaScript 执行后的输出。
    @Published var javaScriptResult = "JavaScript 执行结果会显示在这里。"

    /// 固定脚本提取到的结果。
    @Published var fixedScriptResult = "固定脚本的提取结果会显示在这里。"

    /// 用户可直接阅读的 API 结果文案。
    @Published var apiResponseText = "API 返回结果会显示在这里。"

    /// 原始 API 返回，主要用于调试。
    @Published var rawAPIResponseText = "原始返回会显示在这里。"

    /// 是否展示原始返回，默认关闭。
    @Published var showsRawAPIResponse = false

    /// 弹窗标题，用来区分是成功结果还是失败结果。
    @Published var resultDialogTitle = "API 返回结果"

    /// 是否匹配成功，用于给界面加更醒目的样式。
    @Published var apiMatchSucceeded: Bool?

    /// 匹配到的问题。
    @Published var matchedQuestionText = ""

    /// 题目类型。
    @Published var questionTypeText = ""

    /// 相似度。
    @Published var similarityText = ""

    /// 当前应该展示的答案标签（答案 / 乱序答案）。
    @Published var displayedAnswerLabel = "答案"

    /// 当前应该展示的答案内容。
    @Published var displayedAnswerText = ""

    /// 是否显示结果弹窗。
    @Published var isShowingResultDialog = false

    /// 当前页面标题，用来帮助用户确认现在打开的是哪个页面。
    @Published var pageTitle = "还没有加载网页"

    /// 当前是否正在加载网页。
    @Published var isLoading = false

    /// 是否正在执行固定脚本。
    @Published var isRunningFixedScript = false

    /// 是否正在把结果发送到外部 API。
    @Published var isSendingToAPI = false

    /// 是否可以后退。
    @Published var canGoBack = false

    /// 是否可以前进。
    @Published var canGoForward = false

    /// 最近一次发生的网页加载错误信息。
    @Published var errorMessage: String?

    /// 固定脚本 / API 流程产生的错误信息。
    @Published var fixedScriptErrorMessage: String?

    /// 这里直接持有一个真正的 WKWebView 实例。
    ///
    /// 之所以不在 SwiftUI View 里临时创建，是因为 WebView 有自己的状态：
    /// - 当前页面
    /// - 导航历史
    /// - 页面上下文（执行 JS 也依赖它）
    ///
    /// 如果每次视图刷新都创建新的 WebView，这些状态就会丢失。
    let webView: WKWebView

    private let externalAPIClient = ExternalAPIClient()

    override init() {
        let configuration = WKWebViewConfiguration()

        // 这里显式打开页面 JavaScript，方便你学习时访问普通网页并执行脚本。
        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = webpagePreferences

        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        // 启动应用后先加载一个默认页面，避免界面一打开是空白状态。
        loadCurrentAddress()
    }

    /// 根据地址栏文本加载网页。
    func loadCurrentAddress() {
        guard let url = normalizedURL(from: addressText) else {
            errorMessage = "请输入有效的网址，例如 example.com 或 https://apple.com"
            return
        }

        load(url: url)
    }

    /// 返回上一页。
    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
        syncNavigationState()
    }

    /// 前进到下一页。
    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
        syncNavigationState()
    }

    /// 重新加载当前页面。
    func reload() {
        guard webView.url != nil else {
            loadCurrentAddress()
            return
        }

        webView.reload()
    }

    /// 在当前网页上下文中执行一段用户手动输入的 JavaScript。
    func runJavaScript() {
        let script = javaScriptText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !script.isEmpty else {
            errorMessage = "请先输入要执行的 JavaScript 代码。"
            return
        }

        guard webView.url != nil else {
            errorMessage = "请先成功打开一个网页，再执行 JavaScript。"
            return
        }

        errorMessage = nil
        javaScriptResult = "正在执行 JavaScript..."

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }

            Task { @MainActor in
                if let error {
                    let message = self.describeJavaScriptError(error)
                    self.errorMessage = "JavaScript 执行失败：\(message)"
                    self.javaScriptResult = "执行失败：\(message)"
                    return
                }

                self.errorMessage = nil

                if let result {
                    self.javaScriptResult = String(describing: result)
                } else {
                    self.javaScriptResult = "JavaScript 已执行完成，但返回值是 nil。"
                }
            }
        }
    }

    /// 执行一段内置的固定脚本，并把结果发送到外部 API。
    ///
    /// 这个方法代表一条完整业务链路：
    /// - 执行 JS
    /// - 获取结果
    /// - 调接口上传
    func runFixedScriptAndSend() {
        guard webView.url != nil else {
            fixedScriptErrorMessage = "请先成功打开一个网页，再执行固定脚本。"
            return
        }

        guard !isRunningFixedScript, !isSendingToAPI else {
            return
        }

        fixedScriptErrorMessage = nil
        fixedScriptResult = "正在执行固定脚本..."
        apiResponseText = "等待发送到 API..."
        rawAPIResponseText = "原始返回会显示在这里。"
        showsRawAPIResponse = false
        resultDialogTitle = "API 返回结果"
        apiMatchSucceeded = nil
        matchedQuestionText = ""
        questionTypeText = ""
        similarityText = ""
        displayedAnswerLabel = "答案"
        displayedAnswerText = ""
        isShowingResultDialog = false
        isRunningFixedScript = true
        isSendingToAPI = false

        Task {
            do {
                let result = try await runFixedScript()
                fixedScriptResult = result
                isRunningFixedScript = false

                isSendingToAPI = true
                apiResponseText = "正在发送到 API..."

                let displayResult = try await externalAPIClient.sendQuestion(result)
                apiResponseText = displayResult.statusText
                rawAPIResponseText = displayResult.rawResponse
                fixedScriptErrorMessage = nil
                resultDialogTitle = displayResult.title
                apiMatchSucceeded = displayResult.isSuccess
                matchedQuestionText = displayResult.matchedQuestion ?? ""
                questionTypeText = displayResult.questionType ?? ""
                similarityText = displayResult.similarity ?? ""
                displayedAnswerLabel = displayResult.answerLabel ?? "答案"
                displayedAnswerText = displayResult.displayedAnswer ?? ""
                isShowingResultDialog = true
            } catch {
                let message = describeJavaScriptError(error)
                fixedScriptErrorMessage = message
                fixedScriptResult = "执行失败：\(message)"
                apiResponseText = message
                rawAPIResponseText = "本次没有拿到 API 原始返回。"
                resultDialogTitle = "执行失败"
                apiMatchSucceeded = false
                matchedQuestionText = ""
                questionTypeText = ""
                similarityText = ""
                displayedAnswerLabel = "答案"
                displayedAnswerText = ""
                isShowingResultDialog = true
            }

            isRunningFixedScript = false
            isSendingToAPI = false
        }
    }

    /// 把用户输入转成真正可加载的 URL。
    ///
    /// 规则尽量简单、适合入门：
    /// - 如果用户没有写协议头，就默认补上 https://
    /// - 如果用户显式写了 http:// 或 https://，就按原样使用
    private func normalizedURL(from rawText: String) -> URL? {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else { return nil }

        let urlString: String
        if trimmedText.contains("://") {
            urlString = trimmedText
        } else {
            urlString = "https://\(trimmedText)"
        }

        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            return nil
        }

        return url
    }

    /// 用一个方法统一同步导航相关状态，避免在多个地方重复写相同代码。
    private func syncNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward

        if let currentURL = webView.url?.absoluteString, !currentURL.isEmpty {
            addressText = currentURL
        }

        if let title = webView.title, !title.isEmpty {
            pageTitle = title
        }
    }

    /// 真正向 WebView 发起加载请求。
    private func load(url: URL) {
        addressText = url.absoluteString
        pageTitle = url.host ?? url.absoluteString
        errorMessage = nil

        let request = URLRequest(url: url)
        webView.load(request)
        syncNavigationState()
    }

    /// 执行固定题目提取脚本。
    ///
    /// 这里改成直接 `return` 字符串，而不是继续模拟快捷指令里的 `completion(...)`。
    /// 原因是这段业务脚本本身其实是同步 DOM 读取逻辑，用 `evaluateJavaScript` 直接拿返回值更简单、也更稳定。
    private func runFixedScript() async throws -> String {
        let result = try await evaluateJavaScriptAsync(fixedQuestionScript)

        if let string = result as? String {
            return string
        }

        if let result {
            return String(describing: result)
        }

        return "脚本执行完成，但返回值是 nil。"
    }

    /// 用 Swift Concurrency 包一层 `evaluateJavaScript`，
    /// 这样上层代码就能用 `async/await` 写得更直观。
    private func evaluateJavaScriptAsync(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// 把 WebKit 返回的模糊错误尽量展开成对调试更有帮助的文字。
    private func describeJavaScriptError(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [nsError.localizedDescription]

        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String, !message.isEmpty {
            parts.append("异常信息：\(message)")
        }

        if let line = nsError.userInfo["WKJavaScriptExceptionLineNumber"] {
            parts.append("行号：\(line)")
        }

        if let column = nsError.userInfo["WKJavaScriptExceptionColumnNumber"] {
            parts.append("列号：\(column)")
        }

        return parts.joined(separator: "｜")
    }

    /// 这是根据你原始快捷指令脚本改写后的 WebView 版本。
    ///
    /// 这里额外做了三层加固：
    /// 1. 所有 DOM 文本读取都先判空，避免 `trim()` 打到 `null` / `undefined`
    /// 2. 最外层再包一层 `try/catch`，这样即使页面结构变化，也尽量把错误文字返回给 Swift，
    ///    而不是直接抛出一个模糊的 “A JavaScript exception occurred”
    /// 3. JS 字符串里的换行要写成 `\\n`，否则 Swift 会先把它展开成真正换行，造成 JS 语法错误
    private var fixedQuestionScript: String {
        """
        (function() {
          try {
            function readText(node) {
              if (!node) {
                return '';
              }

              var value = typeof node.textContent === 'string' ? node.textContent : '';
              return value.trim();
            }

            var q = document.querySelector('.questions') || document.querySelector('.questionBank .questions');
            if (!q) {
              return '未找到题目';
            }

            var titleContainer = q.querySelector('.title') || q.querySelector('[class*="title"]');
            if (!titleContainer) {
              return '未找到题目标题容器';
            }

            var spans = titleContainer.querySelectorAll('span');
            var text = '';
            if (spans.length > 1) {
              text = readText(spans[1]);
            } else if (spans.length === 1) {
              text = readText(spans[0]);
            } else {
              text = readText(titleContainer);
            }

            if (!text) {
              return '未提取到题目标题文本';
            }

            var parts = [];
            var lis = q.querySelectorAll('.answer ul li, .answer li');
            for (var i = 0; i < lis.length; i++) {
              var em = lis[i].querySelector('em');
              var sp = lis[i].querySelector('span');
              var optionKey = readText(em);
              var optionText = readText(sp);

              if (optionKey && optionText) {
                parts.push(optionKey + '、' + optionText);
              }
            }

            if (!parts.length) {
              return text + '\\n<<OPTIONS>>\\n未找到选项';
            }

            return text + '\\n<<OPTIONS>>\\n' + parts.join('\\n');
          } catch (error) {
            if (error && error.message) {
              return '脚本异常：' + error.message;
            }

            return '脚本异常：' + String(error);
          }
        })();
        """
    }
}

extension BrowserViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        errorMessage = nil
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        errorMessage = nil
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        isLoading = false
        errorMessage = "网页加载失败：\(error.localizedDescription)"
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        isLoading = false

        #if os(macOS)
        let sandboxHint = "如果你当前运行的是 Mac 版本，这通常还需要启用 outgoing network 权限。"
        #else
        let sandboxHint = "如果是 http:// 网站，请确认 ATS 配置已经生效。"
        #endif

        errorMessage = "网页无法打开：\(error.localizedDescription)。\(sandboxHint)"
        syncNavigationState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        errorMessage = "网页内容进程被系统终止了，请点击刷新重试。"
        syncNavigationState()
    }
}
