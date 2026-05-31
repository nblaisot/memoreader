import Flutter
import UIKit
import open_file_handler
import webview_flutter_wkwebview

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    MemoreaderWebViewSelectionMenu.installIfNeeded()
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    DispatchQueue.main.async { [weak self] in
      self?.registerWebViewSelectionChannel()
    }
    return didFinish
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    OpenFileHandlerPlugin.handleOpenURIs([url])
    return super.application(app, open: url, options: options)
  }

  private func registerWebViewSelectionChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "memoreader/webview_selection",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "UNAVAILABLE", message: "App delegate gone", details: nil))
        return
      }
      switch call.method {
      case "registerWebView":
        guard let args = call.arguments as? [String: Any],
              let webViewId = args["webViewId"] as? Int
        else {
          result(
            FlutterError(
              code: "BAD_ARGS",
              message: "Expected registerWebView args map",
              details: nil
            )
          )
          return
        }
        guard
          let webView = FWFWebViewFlutterWKWebViewExternalAPI.webView(
            forIdentifier: Int64(webViewId),
            withPluginRegistry: self
          )
        else {
          result(
            FlutterError(
              code: "NOT_FOUND",
              message: "WKWebView not found for id \(webViewId)",
              details: nil
            )
          )
          return
        }
        let actionLabel = args["actionLabel"] as? String ?? "Translate"
        let copyLabel = args["copyLabel"] as? String ?? "Copy"
        let selectAllLabel = args["selectAllLabel"] as? String ?? "Select All"
        let actionEnabled = args["actionEnabled"] as? Bool ?? true
        MemoreaderWebViewSelectionMenu.updateLabels(
          action: actionLabel,
          copy: copyLabel,
          selectAll: selectAllLabel,
          enabled: actionEnabled
        )
        MemoreaderWebViewSelectionMenu.register(webView: webView)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
