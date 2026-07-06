import SwiftUI
import WebKit

/// 这是 SwiftUI 和系统原生视图之间的“桥”。
///
/// `WKWebView` 属于平台原生视图：
/// - iOS 上是 UIKit 体系，需要 `UIViewRepresentable`
/// - macOS 上是 AppKit 体系，需要 `NSViewRepresentable`
///
/// 用户目标是学习 iOS，但仓库默认也支持 macOS 构建，
/// 所以这里顺手做成了跨平台包装，避免工程在本机验证时因为平台差异而无法编译。
#if os(iOS)
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 这个示例里，真正的网页加载、前进后退、执行 JS 都在 ViewModel 中完成。
        // 所以 SwiftUI 每次刷新时，这里不需要额外同步任何内容。
    }
}
#elseif os(macOS)
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // macOS 版本和 iOS 版本保持相同思路：
        // WebView 的状态都由 ViewModel 统一管理，这里只负责显示。
    }
}
#endif
