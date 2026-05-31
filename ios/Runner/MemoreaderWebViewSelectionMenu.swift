import Flutter
import UIKit
import WebKit
import webview_flutter_wkwebview

/// Replaces WKWebView's default text-selection menu with Memoreader actions on iOS 16+.
enum MemoreaderWebViewSelectionMenu {
  private static var didInstall = false
  private static weak var registeredWebView: WKWebView?
  private static var actionLabel = "Translate"
  private static var copyLabel = "Copy"
  private static var selectAllLabel = "Select All"
  private static var actionEnabled = true

  static func installIfNeeded() {
    guard !didInstall else { return }
    didInstall = true
    if #available(iOS 16.0, *) {
      swizzle(
        UIResponder.self,
        original: #selector(UIResponder.buildMenu(with:)),
        swizzled: #selector(UIResponder.memoreader_buildMenu(with:))
      )
    }
  }

  static func register(webView: WKWebView) {
    registeredWebView = webView
  }

  static func updateLabels(
    action: String,
    copy: String,
    selectAll: String,
    enabled: Bool
  ) {
    actionLabel = action
    copyLabel = copy
    selectAllLabel = selectAll
    actionEnabled = enabled
  }

  fileprivate static func isWebKitContentView(_ responder: UIResponder) -> Bool {
    let name = String(describing: type(of: responder))
    return name.contains("WKContentView")
  }

  fileprivate static func resolveWebView(from responder: UIResponder) -> WKWebView? {
    if let view = responder as? UIView {
      var current: UIView? = view
      while let candidate = current {
        if let webView = candidate as? WKWebView {
          return webView
        }
        current = candidate.superview
      }
    }
    return registeredWebView
  }

  @available(iOS 16.0, *)
  fileprivate static func customizeMenu(
    builder: UIMenuBuilder,
    webView: WKWebView
  ) {
    var actions: [UIMenuElement] = []

    if actionEnabled {
      let translate = UIAction(
        title: actionLabel,
        identifier: UIAction.Identifier("memoreader.translate")
      ) { _ in
        runSelectionAction(on: webView, action: "translate")
      }
      actions.append(translate)
    }

    let copy = UIAction(
      title: copyLabel,
      identifier: UIAction.Identifier("memoreader.copy")
    ) { _ in
      runSelectionAction(on: webView, action: "copy")
    }
    actions.append(copy)

    let selectAll = UIAction(
      title: selectAllLabel,
      identifier: UIAction.Identifier("memoreader.selectAll")
    ) { _ in
      runSelectionAction(on: webView, action: "selectAll")
    }
    actions.append(selectAll)

    let menu = UIMenu(
      title: "",
      options: .displayInline,
      children: actions
    )
    builder.replace(menu: .standardEdit, with: menu)
  }

  private static func runSelectionAction(on webView: WKWebView, action: String) {
    switch action {
    case "selectAll":
      webView.evaluateJavaScript("MemoReaderApi.selectAll();", completionHandler: nil)
      return
    case "copy":
      webView.evaluateJavaScript(
        "(function(){ return MemoReaderApi.getLastSelectionText(); })();"
      ) { result, _ in
        let text = (result as? String) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UIPasteboard.general.string = trimmed
        webView.evaluateJavaScript("MemoReaderApi.clearSelection();", completionHandler: nil)
      }
      return
    case "translate":
      webView.evaluateJavaScript(
        "MemoReaderApi.triggerSelectionAction();",
        completionHandler: nil
      )
      return
    default:
      return
    }
  }

  private static func swizzle(
    _ type: AnyClass,
    original originalSelector: Selector,
    swizzled swizzledSelector: Selector
  ) {
    guard
      let originalMethod = class_getInstanceMethod(type, originalSelector),
      let swizzledMethod = class_getInstanceMethod(type, swizzledSelector)
    else {
      return
    }
    method_exchangeImplementations(originalMethod, swizzledMethod)
  }
}

private extension UIResponder {
  @available(iOS 16.0, *)
  @objc func memoreader_buildMenu(with builder: UIMenuBuilder) {
    if MemoreaderWebViewSelectionMenu.isWebKitContentView(self),
       let webView = MemoreaderWebViewSelectionMenu.resolveWebView(from: self) {
      MemoreaderWebViewSelectionMenu.customizeMenu(builder: builder, webView: webView)
      return
    }
    memoreader_buildMenu(with: builder)
  }
}
