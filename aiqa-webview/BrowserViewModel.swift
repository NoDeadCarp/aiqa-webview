import Combine
import Foundation
import WebKit

/// 浏览器页面的状态与行为都集中放在这个 ViewModel 里。
///
/// 这样做对初学者有两个好处：
/// 1. SwiftUI 视图只专注于"显示什么"和"按钮点了做什么"。
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

    /// 是否启用自动答题模式：匹配成功后自动选中选项并点击下一题。
    @Published var isAutoMode = false

    /// 是否正在执行自动答题流程（选中选项 + 下一题）。
    @Published var isAutoAnswering = false

    /// 自动答题流程的状态文字。
    @Published var autoAnswerStatus = ""

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

    /// 记录上一题的文本，用于检测题目是否已切换。
    private var lastQuestionText = ""

    /// 启动自动答题循环。
    ///
    /// 流程：提取题目 → 调 API → 选中答案 → 点下一题 → 等新题加载 → 继续循环
    /// 直到下一题按钮不可点击或不存在为止。
    func startAutoLoop() {
        guard !isAutoAnswering else { return }
        isAutoMode = true
        autoAnswerStatus = "自动答题开始..."
        lastQuestionText = ""
        runAutoLoopIteration()
    }

    /// 停止自动答题循环。
    func stopAutoLoop(reason: String) {
        isAutoMode = false
        isAutoAnswering = false
        autoAnswerStatus = reason
    }

    /// 选项状态诊断：抓取 .answer 内每个 li 的完整属性，排查选中/取消机制。
    func captureOptionState() {
        autoAnswerStatus = "正在抓取选项状态..."

        Task {
            do {
                let result = try await evaluateJavaScriptAsync(optionStateScript)
                autoAnswerStatus = result as? String ?? "选项状态抓取完成（无返回内容）"
            } catch {
                autoAnswerStatus = "选项状态抓取失败：\(describeJavaScriptError(error))"
            }
        }
    }

    /// 选项状态专用脚本：输出每个 li 的完整属性、内联样式、父级状态。
    private var optionStateScript: String {
        """
        (function() {
          try {
            var output = [];
            var q = document.querySelector('.questions') || document.querySelector('.questionBank .questions');
            if (!q) return '未找到 .questions 容器';

            var answerDiv = q.querySelector('.answer');
            if (!answerDiv) return '未找到 .answer 容器';

            output.push('========== .answer 容器 ==========');
            output.push('tagName: ' + answerDiv.tagName);
            output.push('className: "' + (answerDiv.className || '') + '"');
            output.push('innerHTML 前200字: ' + answerDiv.innerHTML.substring(0, 200));

            var ul = answerDiv.querySelector('ul');
            if (ul) {
              output.push('');
              output.push('========== ul 容器 ==========');
              output.push('tagName: ' + ul.tagName);
              output.push('className: "' + (ul.className || '') + '"');
            }

            var lis = answerDiv.querySelectorAll('li');
            if (!lis.length) {
              output.push('');
              output.push('未找到 li 元素！answerDiv 的子元素：');
              for (var c = answerDiv.firstElementChild; c; c = c.nextElementSibling) {
                output.push('  ' + c.tagName + ' class="' + (c.className || '') + '" text="' + (c.textContent || '').trim().substring(0, 30) + '"');
              }
            }

            output.push('');
            output.push('========== li 元素详情 ==========');
            for (var i = 0; i < lis.length; i++) {
              var li = lis[i];
              output.push('--- li[' + i + '] ---');
              output.push('  tagName: ' + li.tagName);
              output.push('  className: "' + (li.className || '') + '"');

              // 所有 attribute
              var attrs = [];
              for (var a = 0; a < (li.attributes ? li.attributes.length : 0); a++) {
                var attr = li.attributes[a];
                attrs.push(attr.name + '="' + attr.value + '"');
              }
              output.push('  attributes: [' + attrs.join(', ') + ']');

              // textContent
              output.push('  textContent: "' + (li.textContent || '').trim() + '"');

              // innerHTML
              output.push('  innerHTML: "' + li.innerHTML + '"');

              // 子元素
              var kids = [];
              for (var k = li.firstElementChild; k; k = k.nextElementSibling) {
                kids.push(k.tagName + ' class="' + (k.className || '') + '" text="' + (k.textContent || '').trim() + '"');
              }
              output.push('  children: [' + kids.join(', ') + ']');

              // 计算样式
              try {
                var style = window.getComputedStyle(li);
                output.push('  computed: bg=' + style.backgroundColor + ' color=' + style.color + ' cursor=' + style.cursor + ' pointerEvents=' + style.pointerEvents);
              } catch(e) {
                output.push('  computed: (error)');
              }

              // Vue 数据（如果可访问）
              try {
                if (li.__vue__ || li.__vueParentComponent || li._vnode) {
                  output.push('  VUE: has Vue binding');
                }
                // 检查是否有 Vue 事件
                var vueEvents = li.__vueEventRegistry || li.__vue__;
                if (vueEvents) output.push('  VUE_EVENTS: ' + JSON.stringify(Object.keys(vueEvents)));
              } catch(e) {}

              // 检查是否有 click 事件监听器
              try {
                if (typeof jQuery !== 'undefined' && jQuery._data) {
                  var events = jQuery._data(li, 'events');
                  if (events) output.push('  JQUERY_EVENTS: ' + JSON.stringify(Object.keys(events)));
                }
              } catch(e) {}
            }

            // 检查选项是否有选中状态（任何表示激活的 class）
            output.push('');
            output.push('========== 选中状态分析 ==========');
            for (var i2 = 0; i2 < lis.length; i2++) {
              var li2 = lis[i2];
              var cls2 = (li2.className || '').toString();
              var txt2 = (li2.textContent || '').trim();
              // 猜测选中 class
              var possibleActive = [];
              var clsParts = cls2.split(' ');
              for (var p = 0; p < clsParts.length; p++) {
                var c = clsParts[p].toLowerCase();
                if (c.indexOf('activ') !== -1 || c.indexOf('select') !== -1 ||
                    c.indexOf('check') !== -1 || c.indexOf('cur') !== -1 ||
                    c.indexOf('on') !== -1 || c.indexOf('chosen') !== -1 ||
                    c.indexOf('current') !== -1) {
                  possibleActive.push(clsParts[p]);
                }
              }
              output.push('li[' + i2 + '] ' + txt2 + ' => ' + (possibleActive.length > 0 ? 'POSSIBLE_ACTIVE: ' + possibleActive.join(', ') : 'NO_ACTIVE_CLASS'));
            }

            return output.join('\\n');
          } catch (error) {
            return '选项状态抓取异常：' + (error && error.message ? error.message : String(error));
          }
        })();
        """
    }

    /// DOM 诊断：抓取页面结构，帮助你排查下一题按钮的选择器。
    ///
    /// 输出题目容器附近的 HTML 骨架和所有可交互元素的详细信息。
    func captureDOM() {
        autoAnswerStatus = "正在抓取 DOM 结构..."

        Task {
            do {
                let result = try await evaluateJavaScriptAsync(domCaptureScript)
                autoAnswerStatus = result as? String ?? "DOM 抓取完成（无返回内容）"
            } catch {
                autoAnswerStatus = "DOM 抓取失败：\(describeJavaScriptError(error))"
            }
        }
    }

    /// DOM 结构抓取脚本：输出题目区域附近的 HTML 骨架 + 可点击元素详情。
    private var domCaptureScript: String {
        """
        (function() {
          try {
            function tagOf(el) {
              var t = (el.tagName || '').toLowerCase();
              var cls = (el.className || '').toString();
              var id = el.id || '';
              var txt = (el.textContent || '').trim().substring(0, 40);
              var parts = ['<' + t];
              if (id) parts.push(' id="' + id + '"');
              if (cls) parts.push(' class="' + cls + '"');
              parts.push('>');
              if (txt) parts.push('"' + txt + '"');
              parts.push('</' + t + '>');
              return parts.join('');
            }

            function skeleton(el, depth) {
              depth = depth || 0;
              if (depth > 6) return '';
              var indent = '';
              for (var i = 0; i < depth; i++) indent += '  ';
              var lines = [indent + tagOf(el)];
              for (var c = el.firstElementChild; c; c = c.nextElementSibling) {
                var childLines = skeleton(c, depth + 1);
                if (childLines) lines.push(childLines);
              }
              return lines.join('\\n');
            }

            function describeInteractive(el) {
              var tag = (el.tagName || '').toLowerCase();
              var cls = (el.className || '').toString();
              var id = el.id || '';
              var txt = (el.textContent || '').trim().substring(0, 40);
              var rect = el.getBoundingClientRect();
              var pos = 'top=' + Math.round(rect.top) + ' bottom=' + Math.round(rect.bottom);
              var disabled = '';
              if (el.disabled || cls.indexOf('disabled') !== -1) disabled = ' [DISABLED]';
              var parts = [tag];
              if (id) parts.push('#' + id);
              if (cls) parts.push('.' + cls.split(' ').slice(0, 3).join('.'));
              parts.push('text="' + txt + '"');
              parts.push(pos);
              parts.push(disabled);
              return parts.join(' ');
            }

            var output = [];

            // Part 1: 题目区域的 DOM 结构
            output.push('========== DOM 结构（题目区域） ==========');
            var q = document.querySelector('.questions') || document.querySelector('.questionBank .questions');
            if (q) {
              // 往上找 3 层，输出附近结构
              var root = q;
              for (var up = 0; up < 3; up++) {
                if (root.parentElement) root = root.parentElement;
              }
              output.push(skeleton(root, 0));
            } else {
              output.push('未找到 .questions 容器！');
              // 输出 body 的直接子元素
              var bodyKids = document.body.children;
              for (var b = 0; b < bodyKids.length && b < 20; b++) {
                output.push(tagOf(bodyKids[b]));
              }
            }

            // Part 2: 所有可交互元素
            output.push('');
            output.push('========== 可交互元素（全页） ==========');
            var all = document.querySelectorAll('button, a, [role="button"], [onclick], [class*="btn"], [class*="next"], [class*="button"], [class*="submit"], [class*="link"], [class*="action"], [class*="navigation"]');
            var count = 0;
            for (var i = 0; i < all.length && count < 50; i++) {
              var rect2 = all[i].getBoundingClientRect();
              if (rect2.w < 10 || rect2.h < 10) continue;
              output.push((count + 1) + '. ' + describeInteractive(all[i]));
              count++;
            }

            // Part 3: 题目容器的兄弟元素（最可能是导航栏）
            if (q && q.parentElement) {
              output.push('');
              output.push('========== 题目容器的兄弟元素 ==========');
              var siblings = q.parentElement.children;
              for (var s = 0; s < siblings.length; s++) {
                if (siblings[s] !== q) {
                  output.push(describeInteractive(siblings[s]));
                }
              }
            }

            return output.join('\\n');
          } catch (error) {
            return 'DOM 抓取异常：' + (error && error.message ? error.message : String(error));
          }
        })();
        """
    }

    /// 自动答题的 single iteration：提取→API→选中→下一题→等页面刷新→递归。
    private func runAutoLoopIteration() {
        guard isAutoMode, webView.url != nil else {
            stopAutoLoop(reason: "自动答题已停止。")
            return
        }

        isAutoAnswering = true
        autoAnswerStatus = "正在提取题目..."

        Task {
            do {
                // ---- 第 1 步：提取题目 ----
                let questionText = try await runFixedScript()
                fixedScriptResult = questionText

                // 如果题目和上一轮一样，说明页面还没刷新，轮询等待
                if questionText == lastQuestionText && !lastQuestionText.isEmpty {
                    autoAnswerStatus = "等待新题目加载..."
                    let updated = await waitForPageUpdate(previousQuestion: lastQuestionText)
                    if !updated {
                        // 超时了，题目还是没变，尝试强行点下一题
                        autoAnswerStatus = "题目未变化，尝试强制下一题..."
                        let forceNext = try await evaluateJavaScriptAsync(autoClickNextScript)
                        let forceMsg = forceNext as? String ?? ""
                        if forceMsg.contains("未找到") || forceMsg.contains("禁用") {
                            stopAutoLoop(reason: "答题完成（已无更多题目）。")
                        } else {
                            autoAnswerStatus = forceMsg
                            _ = await waitForPageUpdate(previousQuestion: lastQuestionText)
                            if isAutoMode { runAutoLoopIteration() }
                        }
                        return
                    }
                    // 页面已更新，重新提取
                    let freshText = try await runFixedScript()
                    fixedScriptResult = freshText
                    lastQuestionText = freshText
                } else {
                    lastQuestionText = questionText
                }

                // ---- 第 2 步：调用 API 查答案 ----
                autoAnswerStatus = "正在查询答案..."
                let displayResult = try await externalAPIClient.sendQuestion(lastQuestionText)

                // 更新显示属性（自动模式下不弹窗，静默更新）
                apiResponseText = displayResult.statusText
                rawAPIResponseText = displayResult.rawResponse
                resultDialogTitle = displayResult.title
                apiMatchSucceeded = displayResult.isSuccess
                matchedQuestionText = displayResult.matchedQuestion ?? ""
                questionTypeText = displayResult.questionType ?? ""
                similarityText = displayResult.similarity ?? ""
                displayedAnswerLabel = displayResult.answerLabel ?? "答案"
                displayedAnswerText = displayResult.displayedAnswer ?? ""

                // ---- 第 3 步：校验题目类型一致，再选中答案 ----
                let apiType = displayResult.questionType ?? ""
                let pageType = (try? await evaluateJavaScriptAsync(getPageQuestionTypeScript)) as? String ?? ""
                let typeMatched = apiType.isEmpty || pageType.isEmpty || apiType == pageType

                if displayResult.isSuccess == true, let answer = displayResult.displayedAnswer, !answer.isEmpty {
                    if typeMatched {
                        autoAnswerStatus = "已匹配" + (apiType.isEmpty ? "" : "（题型一致：\(apiType)）") + "，正在选中答案..."
                        let selectScript = autoSelectScript(for: answer)
                        _ = try await evaluateJavaScriptAsync(selectScript)
                    } else {
                        autoAnswerStatus = "题型不匹配（API=\(apiType)，页面=\(pageType)），跳过选中，直接下一题..."
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                } else {
                    autoAnswerStatus = "未匹配，跳过选择..."
                    try await Task.sleep(nanoseconds: 300_000_000)
                }

                // ---- 第 4 步：先检测是否是最后一题 ----
                let lastCheck = try? await evaluateJavaScriptAsync(checkIsLastQuestionScript)
                let lastMsg = lastCheck as? String ?? ""
                if lastMsg.hasPrefix("LAST_QUESTION") {
                    autoAnswerStatus = "已到最后一题（\(lastMsg)），自动停止。"
                    stopAutoLoop(reason: "答题完成（最后一题）。")
                    return
                }

                // ---- 第 5 步：点击下一题 ----
                autoAnswerStatus = "正在点击下一题..."
                let nextResult = try await evaluateJavaScriptAsync(autoClickNextScript)
                let nextMessage = nextResult as? String ?? ""

                if nextMessage.contains("未找到") || nextMessage.contains("disabled")
                    || nextMessage.contains("禁用") || nextMessage.contains("没有") {
                    stopAutoLoop(reason: "答题完成（已无下一题可点）。")
                    return
                }

                autoAnswerStatus = nextMessage

                // ---- 第 6 步：轮询等待页面刷新，题目变了就继续 ----
                _ = await waitForPageUpdate(previousQuestion: lastQuestionText)

                if isAutoMode {
                    runAutoLoopIteration()
                } else {
                    isAutoAnswering = false
                }
            } catch {
                autoAnswerStatus = "出错：\(describeJavaScriptError(error))，重试中..."
                _ = await waitForPageUpdate(previousQuestion: lastQuestionText)
                if isAutoMode {
                    runAutoLoopIteration()
                } else {
                    isAutoAnswering = false
                }
            }
        }
    }

    /// 轮询检测页面是否已切换到新题目。
    ///
    /// 同时检测三个信号，任一个触发即认为页面已刷新：
    /// 1. 题目文本变化
    /// 2. 题目区域 innerHTML 变化（计时器、选项等任何 DOM 变动）
    /// 3. 倒计时器数值变化
    /// 每 200ms 检测一次，最长等 10 秒。
    private func waitForPageUpdate(previousQuestion: String, maxSeconds: Int = 10) async -> Bool {
        let startTime = Date()
        let pollInterval: UInt64 = 200_000_000 // 200ms
        var previousHTML = ""

        // 先记录当前题目区域的 HTML 指纹
        if let html = try? await evaluateJavaScriptAsync(
            "document.querySelector('.questions') ? document.querySelector('.questions').innerHTML : ''"
        ) as? String {
            previousHTML = html
        }

        while Date().timeIntervalSince(startTime) < Double(maxSeconds) {
            try? await Task.sleep(nanoseconds: pollInterval)

            guard isAutoMode else { return false }

            // 多重信号检测
            let checkResult = try? await evaluateJavaScriptAsync(checkPageRefreshScript(previousHTML: previousHTML))
            if let result = checkResult as? String {
                if result.hasPrefix("REFRESHED:") {
                    let msg = String(result.dropFirst("REFRESHED:".count))
                    let elapsed = Int(Date().timeIntervalSince(startTime))
                    autoAnswerStatus = "页面已刷新（\(elapsed*1000)ms）：\(msg)"
                    // 更新 lastQuestionText 为最新题目
                    if let newQ = try? await runFixedScript() {
                        lastQuestionText = newQ
                        fixedScriptResult = newQ
                    }
                    return true
                }
            }

            let elapsed = Int(Date().timeIntervalSince(startTime))
            if elapsed > 0 && elapsed % 3 == 0 {
                autoAnswerStatus = "等待页面刷新... (\(elapsed)s)"
            }
        }

        autoAnswerStatus = "页面刷新超时（\(maxSeconds)s），继续尝试..."
        return false
    }

    /// 生成页面刷新检测 JS，只对比两个可靠信号。
    /// 不再使用计时器（服务端推送，值不稳定）。
    private func checkPageRefreshScript(previousHTML: String) -> String {
        let escapedHTML = jsonEncodedString(previousHTML)
        return """
        (function() {
          var prevHTML = \(escapedHTML);
          var q = document.querySelector('.questions');
          if (!q) return 'NO_QUESTION';

          // 信号1：题目区域 HTML 整体变化（最可靠）
          var curHTML = q.innerHTML;
          if (curHTML !== prevHTML && prevHTML !== '') {
            return 'REFRESHED:DOM变化';
          }

          // 信号2：题号变化（如 "1/32" → "2/32"）
          var marks = document.querySelectorAll('.mark');
          for (var i = 0; i < marks.length; i++) {
            var m = (marks[i].textContent || '').trim();
            if (m.indexOf('/') !== -1 && m !== window.__lastMark) {
              if (window.__lastMark && window.__lastMark !== m) {
                window.__lastMark = m;
                return 'REFRESHED:题号变化(' + m + ')';
              }
              window.__lastMark = m;
            }
          }

          return 'WAITING';
        })();
        """
    }

    /// 根据 API 返回的答案生成"选中选项"的 JS 脚本。
    ///
    /// 支持单选和多选：
    /// - 单选答案 "D" → 选 D
    /// - 多选答案 "AB" 或 "A,B" 或 "A、B" → 选 A 和 B
    private func autoSelectScript(for answer: String) -> String {
        let encodedAnswer = jsonEncodedString(answer)

        return """
        (function() {
          try {
            var answer = \(encodedAnswer);
            if (!answer) return '答案为空，跳过选中。';

            // 解析答案为选项 key 列表（支持多选）
            var answerKeys = [];
            // 格式1："AB"、"ABC" → 拆成单个字母
            if (/^[A-Z]{2,}$/.test(answer)) {
              answerKeys = answer.split('');
            }
            // 格式2："A,B" 或 "A、B" 或 "A,B,C"
            else if (/[A-Z][,、]/.test(answer)) {
              answerKeys = answer.split(/[,、]/).map(function(s) { return s.trim(); }).filter(Boolean);
            }
            // 格式3："A" 单选
            else if (/^[A-Z]$/.test(answer)) {
              answerKeys = [answer];
            }
            // 格式4：可能包含"、"的文字答案，提取首字母
            else {
              var m = answer.match(/[A-Z]/g);
              if (m) answerKeys = m;
            }
            if (!answerKeys.length) {
              // 降级：把整个 answer 当一个 key 试
              answerKeys = [answer];
            }

            var isMulti = answerKeys.length > 1;
            var q = document.querySelector('.questions') || document.querySelector('.questionBank .questions');
            if (!q) return '未找到题目容器，无法自动选中。';

            var lis = q.querySelectorAll('.answer ul li, .answer li');
            if (!lis.length) return '未找到任何选项，无法自动选中。';

            // 辅助：判断一个元素是否处于"选中"状态
            function isSelected(li) {
              // 检查 li 自身 class
              var liCls = (li.className || '').toString();
              if (/\\b(?:on|active|selected|checked|cur|chosen|current)\\b/.test(liCls)) return true;
              // 检查子元素 class（em 或 span 上的 "on" 等标记）
              var kids = li.querySelectorAll('em, span, i, label');
              for (var ki = 0; ki < kids.length; ki++) {
                var kCls = (kids[ki].className || '').toString();
                if (/\\b(?:on|active|selected|checked|cur)\\b/.test(kCls)) return true;
              }
              // 检查 li 自身 attribute
              if (li.getAttribute('aria-selected') === 'true' || li.getAttribute('aria-checked') === 'true') return true;
              return false;
            }

            // 先取消所有已选中的选项（li 点击是 toggle，再点一次会取消）
            var cleared = 0;
            for (var c = 0; c < lis.length; c++) {
              if (isSelected(lis[c])) {
                lis[c].click();
                cleared++;
              }
            }

            // 遍历所有选项，点击匹配的
            var clicked = [];
            var allOptions = [];

            for (var i = 0; i < lis.length; i++) {
              var em = lis[i].querySelector('em');
              var span = lis[i].querySelector('span');
              var key = em ? (em.textContent || '').trim() : '';
              var text = span ? (span.textContent || '').trim() : '';

              // 无 em/span：li 文本如 "D利率低"，首字符是 key
              if (!key) {
                var rawText = (lis[i].textContent || '').trim();
                if (rawText.length > 0) {
                  key = rawText.charAt(0);
                  text = rawText.substring(1);
                }
              }

              var fullOption = key && text ? key + '、' + text : (key || text);
              allOptions.push(fullOption || '(空)');

              // 检测这个选项是否匹配答案中的任意一个 key
              var matched = false;
              for (var k = 0; k < answerKeys.length; k++) {
                var ak = answerKeys[k];
                if (key === ak || text === ak || fullOption === ak ||
                    (ak.length === 1 && key === ak)) {
                  matched = true;
                  break;
                }
              }

              if (matched) {
                lis[i].click();
                clicked.push(key || text);
              }
            }

            if (clicked.length > 0) {
              return '已选中' + (isMulti ? '(' + clicked.length + '个) ' : '') + '：' + clicked.join(', ') + ' | 选项：' + allOptions.join(', ');
            }

            return '未找到匹配选项。答案keys=' + JSON.stringify(answerKeys) + ' | 页面选项：' + allOptions.join(', ');
          } catch (error) {
            if (error && error.message) {
              return '自动选中异常：' + error.message;
            }
            return '自动选中异常：' + String(error);
          }
        })();
        """
    }

    /// 从页面提取题目类型（如 "单选"、"多选"）。
    private var getPageQuestionTypeScript: String {
        """
        (function() {
          try {
            var q = document.querySelector('.questions') || document.querySelector('.questionBank .questions');
            if (!q) return '';
            var titleEl = q.querySelector('.title');
            if (!titleEl) return '';
            // .title 内第一个 em 通常是题型标记（如 <em class="singcolor">单选</em>）
            var em = titleEl.querySelector('em');
            if (em) return (em.textContent || '').trim();
            // 降级：整个 title 文字里找
            var txt = (titleEl.textContent || '').trim();
            if (txt.indexOf('多选') !== -1) return '多选';
            if (txt.indexOf('单选') !== -1) return '单选';
            if (txt.indexOf('判断') !== -1) return '判断';
            return '';
          } catch(e) { return ''; }
        })();
        """
    }

    /// 检测是否已是最后一题（下一题按钮被禁用、或题号显示 32/32 等）。
    /// 返回 true 表示应该停止。
    private var checkIsLastQuestionScript: String {
        """
        (function() {
          try {
            // 策略 1：检测"下一题"按钮是否 disabled
            var btns = document.querySelectorAll('button');
            for (var i = 0; i < btns.length; i++) {
              var t = (btns[i].textContent || '').trim();
              if (t === '下一题' || t.indexOf('下一题') !== -1) {
                if (btns[i].disabled || (btns[i].className || '').indexOf('disabled') !== -1) {
                  return 'LAST_QUESTION:下一题按钮已禁用';
                }
              }
            }

            // 策略 2：解析题号 "32/32"
            var marks = document.querySelectorAll('.mark');
            for (var j = 0; j < marks.length; j++) {
              var m = (marks[j].textContent || '').trim();
              var match = m.match(/(\\d+)\\s*\\/\\s*(\\d+)/);
              if (match) {
                var cur = parseInt(match[1], 10);
                var total = parseInt(match[2], 10);
                if (cur >= total) {
                  return 'LAST_QUESTION:题号' + cur + '/' + total;
                }
              }
            }

            return 'NOT_LAST';
          } catch(e) {
            return 'CHECK_ERROR:' + (e.message || String(e));
          }
        })();
        """
    }

    /// 点击"下一题"按钮的 JS 脚本。
    ///
    /// 核心思路：不再猜选择器，而是分析 DOM 树结构。
    /// 找到题目容器 → 往上逐层扫描父级 → 找同级/附近的导航元素 → 评分排序 → 点击最高分。
    /// 注意：会过滤掉"交卷""提交"等结束类按钮，只点击真正的导航按钮。
    private var autoClickNextScript: String {
        """
        (function() {
          try {
            // ---- 工具函数 ----
            function forceClick(el) {
              el.click();
              try {
                ['touchstart','touchend','mousedown','mouseup'].forEach(function(name) {
                  el.dispatchEvent(new Event(name, {bubbles: true, cancelable: true}));
                });
              } catch(e) {}
            }

            function isDisabled(el) {
              if (!el) return true;
              if (el.disabled) return true;
              var cls = (el.className || '').toString();
              if (cls.indexOf('disabled') !== -1 || cls.indexOf('is-disabled') !== -1) return true;
              if (el.getAttribute('aria-disabled') === 'true') return true;
              return false;
            }

            function getText(el) { return (el.textContent || el.innerText || '').trim(); }
            function getOwnText(el) {
              var t = '';
              for (var c = el.firstChild; c; c = c.nextSibling) {
                if (c.nodeType === 3) t += c.textContent;
              }
              return t.trim();
            }

            function describe(el) {
              if (!el) return '(null)';
              var tag = (el.tagName || '').toLowerCase();
              var cls = (el.className || '').toString();
              var id = el.id || '';
              var txt = getText(el).substring(0, 30);
              var parts = [tag];
              if (id) parts.push('#' + id);
              if (cls) parts.push('.' + cls.split(' ').slice(0, 3).join('.'));
              parts.push('"' + txt + '"');
              if (isDisabled(el)) parts.push('[DISABLED]');
              return parts.join(' ');
            }

            function getBounding(el) {
              var r = el.getBoundingClientRect();
              return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, w: r.width, h: r.height };
            }

            var KEYWORDS = ['下一题', '下一頁', '下一首', '继续', 'next', 'Next', 'NEXT', '下一'];
            // 结束类按钮：扣分，防止最后一题时误点"交卷"
            var STOP_WORDS = ['交卷', '提交', 'submit', 'Submit', '确定', '结束', '完成'];

            // ==========================================
            // 核心：分析 DOM 树，找到题目容器附近的导航元素
            // ==========================================

            // Step 1: 定位题目容器
            var questionEl = document.querySelector('.questions') || document.querySelector('.questionBank .questions');
            if (!questionEl) {
              // 降级：全页扫描
              return fallbackScan();
            }

            // Step 2: 从题目容器往上逐层找"导航栏容器"
            // 导航栏通常是题目容器的兄弟节点，或在父级的末尾/开头
            var candidates = [];
            var seen = new WeakSet();
            var ancestor = questionEl;

            // 往上走 5 层，每一层扫描兄弟节点和父级内所有元素
            for (var level = 0; level < 5 && ancestor; level++) {
              var parent = ancestor.parentElement;
              if (!parent) break;

              // 扫描当前层级的所有子元素
              var children = parent.children;
              for (var i = 0; i < children.length; i++) {
                var child = children[i];
                if (seen.has(child)) continue;
                if (child === questionEl) continue;
                if (child.contains && child.contains(questionEl)) continue; // 跳过题目容器的祖先（往上走会碰到）

                // 收集这个子元素及其内部所有可交互元素
                collectCandidates(child, level);
              }

              ancestor = parent;
            }

            // 也扫描题目容器内部的可能按钮（有些页面把导航放在题目容器内底部）
            collectCandidates(questionEl, 0);

            function collectCandidates(root, level) {
              var interactives = root.querySelectorAll('button, a, [role="button"], [onclick], [class*="btn"], [class*="next"], [class*="button"], [class*="submit"], [class*="link"], li, span, div');
              for (var i = 0; i < interactives.length; i++) {
                var el = interactives[i];
                if (seen.has(el)) continue;
                if (isDisabled(el)) continue;
                seen.add(el);

                var txt = getText(el);
                var ownTxt = getOwnText(el);
                var rect = getBounding(el);

                // 过滤：必须在可见区域内、有合理尺寸
                if (rect.w < 20 || rect.h < 20) continue;
                if (rect.top < -200 || rect.top > window.innerHeight + 200) continue;

                // 评分
                var score = 0;

                // a) 文字包含关键词（最重要）
                for (var k = 0; k < KEYWORDS.length; k++) {
                  if (txt.indexOf(KEYWORDS[k]) !== -1) score += 50;
                  if (ownTxt.indexOf(KEYWORDS[k]) !== -1) score += 30;
                }
                // 黑名单：交卷、提交等结束按钮直接排除
                for (var s = 0; s < STOP_WORDS.length; s++) {
                  if (txt.indexOf(STOP_WORDS[s]) !== -1 || ownTxt.indexOf(STOP_WORDS[s]) !== -1) {
                    score = -999; // 直接淘汰
                  }
                }

                // b) 文字短（2-10字），更像按钮
                if (txt.length >= 1 && txt.length <= 10) score += 20;

                // c) 在题目区域下方（位置靠后）
                var qRect = getBounding(questionEl);
                if (rect.top >= qRect.bottom - 20) score += 15;

                // d) 在屏幕下半部分
                if (rect.top > window.innerHeight * 0.35) score += 10;

                // e) 外观像按钮（有特定 class 或样式）
                var cls = (el.className || '').toString();
                if (cls.indexOf('btn') !== -1 || cls.indexOf('button') !== -1 || cls.indexOf('next') !== -1) score += 15;
                if (el.tagName === 'BUTTON' || el.tagName === 'A') score += 10;

                // f) 元素有 cursor:pointer 样式
                try {
                  var style = window.getComputedStyle(el);
                  if (style.cursor === 'pointer') score += 10;
                  if (style.backgroundColor && style.backgroundColor !== 'rgba(0, 0, 0, 0)' && style.backgroundColor !== 'transparent') score += 5;
                } catch(e) {}

                if (score > 0) {
                  candidates.push({
                    el: el,
                    score: score,
                    level: level,
                    desc: describe(el),
                    text: txt,
                    rectTop: rect.top
                  });
                }
              }
            }

            // Step 3: 按评分排序
            candidates.sort(function(a, b) {
              if (b.score !== a.score) return b.score - a.score;
              return b.rectTop - a.rectTop; // 同分按下位置排
            });

            // Step 4: 点击最高分候选
            if (candidates.length > 0) {
              var best = candidates[0];
              forceClick(best.el);
              return '已点击：' + best.desc;
            }

            // Step 5: 全都没找到，输出诊断
            return fallbackScan();

            function fallbackScan() {
              // 终极降级：全页扫描所有可点击元素
              var all = document.querySelectorAll('button, a, [role="button"], [onclick], [class*="btn"], [class*="next"], [class*="button"], [class*="submit"], [class*="link"]');
              var info = [];
              for (var n = 0; n < all.length && n < 40; n++) {
                var el = all[n];
                if (!isDisabled(el)) {
                  info.push(describe(el));
                }
              }
              // 如果还没有，扩大范围
              if (!info.length) {
                var all2 = document.querySelectorAll('li, span, div');
                for (var m = 0; m < all2.length && info.length < 40; m++) {
                  var el2 = all2[m];
                  var t2 = getText(el2);
                  var c2 = (el2.className || '').toString();
                  if (t2 && t2.length >= 2 && t2.length <= 12 && (c2.indexOf('btn') !== -1 || c2.indexOf('next') !== -1 || c2.indexOf('button') !== -1)) {
                    info.push(describe(el2));
                  }
                }
              }
              return '未找到下一题按钮。\\n页面可交互元素（前40个）：\\n' + (info.length ? info.join('\\n') : '（无）');
            }
          } catch (error) {
            return '点击下一题异常：' + (error && error.message ? error.message : String(error));
          }
        })();
        """
    }

    /// 把 Swift 字符串编码成安全的 JSON 字面量，避免嵌入 JS 时出现转义问题。
    private func jsonEncodedString(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let json = String(data: data, encoding: .utf8) else {
            // 降级：手动做基础转义
            var escaped = string
            escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\")
            escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
            escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
            escaped = escaped.replacingOccurrences(of: "\r", with: "\\r")
            return "\"\(escaped)\""
        }
        return json
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
    ///    而不是直接抛出一个模糊的 "A JavaScript exception occurred"
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
                // 有 em/span 结构：em=key, span=text
                parts.push(optionKey + '、' + optionText);
              } else {
                // 无 em/span：直接用 li 文本（如 "A额度高"）
                var liText = readText(lis[i]);
                if (liText) {
                  parts.push(liText);
                }
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
