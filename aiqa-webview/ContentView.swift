import SwiftUI

struct ContentView: View {
    /// `@StateObject` 适合在当前页面“创建并持有”一个可观察对象。
    ///
    /// 这里用它来持有 BrowserViewModel，保证页面刷新时不会重复创建 WebView。
    @StateObject private var viewModel = BrowserViewModel()

    /// 是否显示底部工具栏（地址栏、功能按钮、状态信息）。
    @State private var isToolbarVisible = true

    /// 悬浮球当前位置（窗口坐标系）。为 nil 时按上次保存的相对位置计算。
    @State private var ballCenter: CGPoint?

    /// 开始拖动时球心的位置，用位移计算新位置，避免球突然跳到手指下面。
    @State private var ballDragStartCenter: CGPoint?

    /// 是否正在拖动（用于轻微放大反馈，也用于区分“点击”和“拖动”）。
    @State private var isDraggingBall = false

    /// 底部栏是否是被“自动答题”自动收起的：
    /// 自动答题结束时会自动恢复；如果用户中途手动切换过，就不再干预。
    @State private var toolbarHiddenByAuto = false

    /// 悬浮球位置以相对比例保存，窗口尺寸变化后也不会跑出屏幕。
    @AppStorage("floatingBallXRatio") private var ballXRatio = 0.94
    @AppStorage("floatingBallYRatio") private var ballYRatio = 0.55

    private let ballDiameter: CGFloat = 46

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                pageArea

                // 悬浮球永远在最上层，可拖动、可点击。
                floatingBall(in: proxy.size)
            }
        }
        // 工具栏隐藏时让整个页面铺到屏幕最底部。
        // 否则 iOS 底部安全区（Home Indicator 那条）会露出窗口底色，看起来像残留的白边。
        .ignoresSafeArea(.container, edges: isToolbarVisible ? [] : .bottom)
        .sheet(isPresented: $viewModel.isShowingResultDialog) {
            resultSheet
        }
        .onChange(of: viewModel.isAutoMode) { _, isAutoMode in
            handleAutoModeChange(isAutoMode)
        }
#if os(macOS)
        // Mac 版浏览器窗口给大一点，更接近真正浏览器的使用习惯。
        .frame(minWidth: 1100, minHeight: 760)
#endif
    }

    /// 网页 + 底部工具栏。
    /// 工具栏隐藏后这里只剩网页，加载指示也不会再显示。
    private var pageArea: some View {
        VStack(spacing: 0) {
            WebViewContainer(webView: viewModel.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if viewModel.isLoading, isToolbarVisible {
                        ProgressView()
                            .controlSize(.small)
                            .padding(12)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                }

            if isToolbarVisible {
                bottomToolbar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - 悬浮球

    /// 悬浮球：可拖到窗口任意位置，点击显示 / 隐藏底部工具栏。
    private func floatingBall(in containerSize: CGSize) -> some View {
        let center = clampedBallCenter(
            ballCenter ?? defaultBallCenter(in: containerSize),
            in: containerSize
        )

        return ZStack {
            Circle()
                .fill(.regularMaterial)

            Circle()
                .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)

            Image(systemName: isToolbarVisible ? "chevron.down" : "chevron.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.secondary)

            // 自动答题进行中只用一个绿色圆环提示，不显示任何文字状态。
            if viewModel.isAutoAnswering {
                Circle()
                    .stroke(Color.green.opacity(0.85), lineWidth: 2)
            }
        }
        .frame(width: ballDiameter, height: ballDiameter)
        .contentShape(Circle())
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .scaleEffect(isDraggingBall ? 1.08 : 1)
        .gesture(dragGesture(in: containerSize, currentCenter: center))
        .accessibilityLabel(isToolbarVisible ? "隐藏工具栏" : "显示工具栏")
#if os(macOS)
        .help(isToolbarVisible ? "隐藏工具栏" : "显示工具栏")
#endif
        .position(center)
    }

    /// 拖动与点击共用同一个手势：位移超过阈值算拖动，否则算点击。
    private func dragGesture(in containerSize: CGSize, currentCenter: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let translation = value.translation

                if !isDraggingBall {
                    let distanceSquared = translation.width * translation.width
                        + translation.height * translation.height
                    guard distanceSquared > 36 else { return }

                    isDraggingBall = true
                    ballDragStartCenter = currentCenter
                }

                guard let start = ballDragStartCenter else { return }

                let dragged = CGPoint(
                    x: start.x + translation.width,
                    y: start.y + translation.height
                )
                ballCenter = clampedBallCenter(dragged, in: containerSize)
            }
            .onEnded { _ in
                let wasDragging = isDraggingBall
                isDraggingBall = false
                ballDragStartCenter = nil

                if wasDragging {
                    guard let finalCenter = ballCenter else { return }
                    let clamped = clampedBallCenter(finalCenter, in: containerSize)
                    ballCenter = clamped

                    // 保存相对比例，下次启动 / 窗口缩放后位置依然合理。
                    ballXRatio = Double(clamped.x / max(containerSize.width, 1))
                    ballYRatio = Double(clamped.y / max(containerSize.height, 1))
                } else {
                    // 基本没有位移：当成点击，切换工具栏显隐。
                    toggleToolbarVisibility()
                }
            }
    }

    private func defaultBallCenter(in containerSize: CGSize) -> CGPoint {
        CGPoint(
            x: containerSize.width * ballXRatio,
            y: containerSize.height * ballYRatio
        )
    }

    /// 保证球始终完整留在窗口内。
    private func clampedBallCenter(_ center: CGPoint, in containerSize: CGSize) -> CGPoint {
        let margin = ballDiameter / 2 + 8

        return CGPoint(
            x: min(max(center.x, margin), max(margin, containerSize.width - margin)),
            y: min(max(center.y, margin), max(margin, containerSize.height - margin))
        )
    }

    private func toggleToolbarVisibility() {
        // 用户手动切换过，就不再让“自动答题结束”去恢复它。
        toolbarHiddenByAuto = false

        withAnimation(.easeInOut(duration: 0.2)) {
            isToolbarVisible.toggle()
        }
    }

    /// 自动答题开始 / 结束时联动工具栏：
    /// - 开始：自动收起底部栏，只保留网页和悬浮球，不显示状态信息
    /// - 结束：如果此前是被自动收起的，就自动恢复，方便查看最终结果
    private func handleAutoModeChange(_ isAutoMode: Bool) {
        if isAutoMode {
            if isToolbarVisible {
                toolbarHiddenByAuto = true
                withAnimation(.easeInOut(duration: 0.2)) {
                    isToolbarVisible = false
                }
            }
        } else if toolbarHiddenByAuto {
            toolbarHiddenByAuto = false
            withAnimation(.easeInOut(duration: 0.2)) {
                isToolbarVisible = true
            }
        }
    }

    /// 底部工具栏改成更接近 Safari 的思路：
    /// - 导航按钮保持在底部
    /// - 地址输入框也放在底部，不再占用顶部空间
    /// - JS 按钮放在地址栏旁边，方便一键执行
    private var bottomToolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                toolbarIconButton(systemImage: "chevron.backward", action: viewModel.goBack)
                    .disabled(!viewModel.canGoBack)

                toolbarIconButton(systemImage: "chevron.forward", action: viewModel.goForward)
                    .disabled(!viewModel.canGoForward)

                toolbarIconButton(systemImage: "arrow.clockwise", action: viewModel.reload)

                addressField

                Button {
                    viewModel.runFixedScriptAndSend()
                } label: {
                    Image(systemName: executeJSIconName)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.16))
                )
                .disabled(viewModel.isRunningFixedScript || viewModel.isSendingToAPI)

                // 自动答题按钮：点击开始循环答题；再点停止
                Button {
                    if viewModel.isAutoMode {
                        viewModel.stopAutoLoop(reason: "已手动停止。")
                    } else {
                        viewModel.startAutoLoop()
                    }
                } label: {
                    Image(systemName: viewModel.isAutoMode ? "stop.fill" : "forward.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .background(
                    Circle()
                        .fill(viewModel.isAutoMode ? Color.red.opacity(0.18) : Color.green.opacity(0.20))
                )
#if os(macOS)
                .help("自动答题：点击开始/停止循环")
#endif

                // DOM 诊断按钮：查看页面结构，方便调试选择器
                Button {
                    viewModel.captureDOM()
                } label: {
                    Image(systemName: "rectangle.and.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(
                    Circle()
                        .fill(Color.orange.opacity(0.18))
                )
#if os(macOS)
                .help("DOM 诊断：抓取页面结构")
#endif

                // 选项状态诊断按钮
                Button {
                    viewModel.captureOptionState()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(
                    Circle()
                        .fill(Color.purple.opacity(0.18))
                )
#if os(macOS)
                .help("选项诊断：查看 li 元素属性")
#endif
            }

            if let errorMessage = viewModel.errorMessage {
                errorBanner(message: errorMessage)
            }

            if !viewModel.autoAnswerStatus.isEmpty {
                autoAnswerStatusBanner
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private var addressField: some View {
#if os(iOS)
        TextField("输入网址", text: $viewModel.addressText)
            .textFieldStyle(.plain)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.10))
            )
            .overlay {
                Capsule()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
            .onSubmit {
                viewModel.loadCurrentAddress()
            }
#else
        TextField("输入网址", text: $viewModel.addressText)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(0.10))
            )
            .overlay {
                Capsule()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
            .onSubmit {
                viewModel.loadCurrentAddress()
            }
#endif
    }

    /// API 返回结果用 sheet 展示，比 alert 更适合显示较长文本。
    ///
    /// 用户首先看到的是整理后的通俗结果；
    /// 原始返回单独收纳在开关后面，默认关闭，避免一上来把页面弄得很乱。
    private var resultSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(viewModel.resultDialogTitle)
                        .font(.title3)
                        .fontWeight(.bold)

                    Spacer()

                    Button("复制") {
                        ClipboardHelper.copy(resultSheetCopyText)
                    }
                    .buttonStyle(.bordered)

                    Button("关闭") {
                        viewModel.isShowingResultDialog = false
                    }
                    .buttonStyle(.bordered)
                }

                resultHeroCard

                if !viewModel.matchedQuestionText.isEmpty {
                    resultBlock(
                        title: "匹配到的问题",
                        text: viewModel.matchedQuestionText,
                        accent: .blue
                    )
                }

                if !viewModel.displayedAnswerText.isEmpty {
                    resultBlock(
                        title: viewModel.displayedAnswerLabel,
                        text: viewModel.displayedAnswerText,
                        accent: .green,
                        emphasize: true
                    )
                }

                HStack(spacing: 12) {
                    if !viewModel.questionTypeText.isEmpty {
                        metricPill(title: "题目类型", value: viewModel.questionTypeText)
                    }

                    if !viewModel.similarityText.isEmpty {
                        metricPill(title: "相似度", value: viewModel.similarityText)
                    }
                }

                resultBlock(
                    title: "本次提取的题目内容",
                    text: viewModel.fixedScriptResult,
                    accent: .orange
                )

                Toggle("显示原始返回（调试用）", isOn: $viewModel.showsRawAPIResponse)
                    .toggleStyle(.switch)

                if viewModel.showsRawAPIResponse {
                    resultBlock(
                        title: "原始 API 返回",
                        text: viewModel.rawAPIResponseText,
                        accent: .gray
                    )
                }
            }
            .padding(20)
        }
#if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
#endif
    }

    /// 结果顶部卡片：突出“成功 / 失败”与一句简洁结论。
    private var resultHeroCard: some View {
        let accent = resultAccentColor

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: resultHeroIcon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(accent)

                Text(resultHeroTitle)
                    .font(.headline)
                    .fontWeight(.bold)
            }

            Text(viewModel.apiResponseText)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(accent.opacity(0.12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        }
    }

    private var resultHeroTitle: String {
        switch viewModel.apiMatchSucceeded {
        case true:
            return "已成功匹配到结果"
        case false:
            return "本次没有匹配成功"
        case nil:
            return viewModel.resultDialogTitle
        }
    }

    private var resultHeroIcon: String {
        switch viewModel.apiMatchSucceeded {
        case true:
            return "checkmark.seal.fill"
        case false:
            return "xmark.octagon.fill"
        case nil:
            return "info.circle.fill"
        }
    }

    private var resultAccentColor: Color {
        switch viewModel.apiMatchSucceeded {
        case true:
            return .green
        case false:
            return .red
        case nil:
            return .blue
        }
    }

    private func resultBlock(title: String, text: String, accent: Color, emphasize: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(accent)

            ScrollView {
                Text(text)
                    .font(.system(emphasize ? .body : .footnote, design: .monospaced))
                    .fontWeight(emphasize ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(minHeight: emphasize ? 88 : 120)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(accent.opacity(emphasize ? 0.12 : 0.08))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accent.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var executeJSIconName: String {
        if viewModel.isRunningFixedScript {
            return "hourglass"
        }

        if viewModel.isSendingToAPI {
            return "paperplane"
        }

        return "bolt.fill"
    }

    private var resultSheetCopyText: String {
        """
        \(viewModel.resultDialogTitle)

        结果说明：
        \(viewModel.apiResponseText)

        匹配到的问题：
        \(viewModel.matchedQuestionText)

        \(viewModel.displayedAnswerLabel)：
        \(viewModel.displayedAnswerText)

        题目类型：\(viewModel.questionTypeText)
        相似度：\(viewModel.similarityText)

        本次提取的题目内容：
        \(viewModel.fixedScriptResult)

        原始 API 返回：
        \(viewModel.rawAPIResponseText)
        """
    }

    private func toolbarIconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private func errorBanner(message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.08))
    }

    private var autoAnswerStatusBanner: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                if viewModel.isAutoAnswering {
                    ProgressView()
                        .controlSize(.small)
                    Text("自动答题中...")
                        .font(.caption)
                        .fontWeight(.medium)
                } else {
                    Image(systemName: statusBannerIcon)
                        .font(.caption)
                        .foregroundStyle(statusBannerColor)
                    Text("状态信息")
                        .font(.caption)
                        .fontWeight(.medium)
                }

                Spacer()

                Button {
                    ClipboardHelper.copy(viewModel.autoAnswerStatus)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.autoAnswerStatus = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // 内容区：上下滚动
            ScrollView(.vertical, showsIndicators: true) {
                Text(viewModel.autoAnswerStatus)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(statusBannerColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusBannerColor.opacity(0.18), lineWidth: 1)
        )
        .padding(.horizontal, 8)
    }

    private var statusBannerIcon: String {
        let s = viewModel.autoAnswerStatus
        if s.contains("失败") || s.contains("异常") { return "exclamationmark.triangle.fill" }
        if s.contains("未找到") || s.contains("未匹配") { return "info.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var statusBannerColor: Color {
        let s = viewModel.autoAnswerStatus
        if s.contains("失败") || s.contains("异常") { return .orange }
        if s.contains("未找到") || s.contains("未匹配") { return .blue }
        return .green
    }
}

#Preview {
    ContentView()
}
