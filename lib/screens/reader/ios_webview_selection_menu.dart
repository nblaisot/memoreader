import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

const _channel = MethodChannel('memoreader/webview_selection');

/// iOS 16+: customize WKWebView's native selection menu instead of a Flutter overlay.
class IosWebViewSelectionMenu {
  IosWebViewSelectionMenu._();

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static Future<void> registerWebView({
    required WebViewController controller,
    required String actionLabel,
    required String copyLabel,
    required String selectAllLabel,
    required bool actionEnabled,
  }) async {
    if (!isSupported) {
      return;
    }
    final platform = controller.platform;
    if (platform is! WebKitWebViewController) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('registerWebView', {
        'webViewId': platform.webViewIdentifier,
        'actionLabel': actionLabel,
        'copyLabel': copyLabel,
        'selectAllLabel': selectAllLabel,
        'actionEnabled': actionEnabled,
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[WebView] iOS native selection menu register failed: $e');
      }
    }
  }
}
