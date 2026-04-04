import AppKit
import WebKit

/// Manages a visible WKWebView login window for claude.ai or platform.claude.com.
final class LoginWindowController: NSWindowController, WKNavigationDelegate {
    private let webView: WKWebView
    private let successPredicate: (URL) -> Bool
    private var onSuccess: (() -> Void)?

    private init(url: URL, title: String, successPredicate: @escaping (URL) -> Bool, onSuccess: @escaping () -> Void) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 680), configuration: cfg)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = wv
        window.center()

        self.webView = wv
        self.successPredicate = successPredicate
        self.onSuccess = onSuccess
        super.init(window: window)
        wv.navigationDelegate = self
        wv.load(URLRequest(url: url))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Factory

    static func openClaude(onSuccess: @escaping () -> Void) {
        let ctrl = LoginWindowController(
            url: URL(string: "https://claude.ai/login")!,
            title: "Login to Claude",
            successPredicate: { url in
                url.host?.contains("claude.ai") == true &&
                !url.path.contains("login") &&
                !url.path.contains("signup")
            },
            onSuccess: onSuccess
        )
        ctrl.showWindow(nil)
        // Retain until closed
        objc_setAssociatedObject(ctrl.window!, &AssociatedKey.controller, ctrl, .OBJC_ASSOCIATION_RETAIN)
    }

    static func openPlatform(onSuccess: @escaping () -> Void) {
        let ctrl = LoginWindowController(
            url: URL(string: "https://platform.claude.com/settings/billing")!,
            title: "Login to Claude Platform",
            successPredicate: { url in
                url.host?.contains("platform.claude.com") == true &&
                url.path.contains("billing")
            },
            onSuccess: onSuccess
        )
        ctrl.showWindow(nil)
        objc_setAssociatedObject(ctrl.window!, &AssociatedKey.controller, ctrl, .OBJC_ASSOCIATION_RETAIN)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        if successPredicate(url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.onSuccess?()
                self?.onSuccess = nil
                self?.close()
            }
        }
    }
}

private enum AssociatedKey {
    static var controller = "LoginWindowController"
}
