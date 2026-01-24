import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// True when running on macOS. Used to skip APIs not implemented on macOS
/// (e.g. WebView setBackgroundColor/opaque) without affecting iOS/Android.
bool get _isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

class WebViewPageUpdate {
  const WebViewPageUpdate({
    required this.pageIndex,
    required this.pageCount,
    required this.totalChars,
    required this.startCharIndex,
    required this.endCharIndex,
  });

  final int pageIndex;
  final int pageCount;
  final int totalChars;
  final int? startCharIndex;
  final int? endCharIndex;
}

class WebViewSelection {
  const WebViewSelection({
    required this.text,
    required this.rect,
  });

  final String text;
  final Rect rect;
}

class WebViewPageRange {
  const WebViewPageRange({
    required this.pageIndex,
    required this.startCharIndex,
    required this.endCharIndex,
  });

  final int pageIndex;
  final int? startCharIndex;
  final int? endCharIndex;
}

class WebViewReaderController {
  WebViewController? _controller;
  final Completer<void> _readyCompleter = Completer<void>();

  bool get isAttached => _controller != null;
  bool get isReady => _readyCompleter.isCompleted;

  void attach(WebViewController controller) {
    _controller = controller;
  }

  void markReady() {
    if (!_readyCompleter.isCompleted) {
      _readyCompleter.complete();
    }
  }

  Future<void> waitUntilReady() => _readyCompleter.future;

  Future<void> updateStyles({
    required double fontSize,
    required double lineHeight,
    required Color textColor,
    required Color backgroundColor,
    required double paddingX,
    required double paddingY,
  }) {
    final payload = jsonEncode({
      'fontSize': fontSize,
      'lineHeight': lineHeight,
      'textColor': _colorToCss(textColor),
      'backgroundColor': _colorToCss(backgroundColor),
      'paddingX': paddingX,
      'paddingY': paddingY,
    });
    return _runJs('MemoReaderApi.updateStyles($payload);');
  }

  Future<void> updateActionLabel(String label) {
    return _runJs('MemoReaderApi.setActionLabel(${jsonEncode(label)});');
  }

  Future<void> setActionEnabled(bool enabled) {
    return _runJs('MemoReaderApi.setActionEnabled(${enabled ? 'true' : 'false'});');
  }

  Future<void> clearSelection() {
    return _runJs('MemoReaderApi.clearSelection();');
  }

  Future<void> selectAll() {
    return _runJs('MemoReaderApi.selectAll();');
  }

  Future<String?> getVisibleText() async {
    final result = await _runJsReturning('MemoReaderApi.getVisibleText();');
    return _parseJsString(result);
  }

  Future<WebViewPageRange?> getPageInfo(int pageIndex) async {
    final result =
        await _runJsReturning('MemoReaderApi.getPageInfo($pageIndex);');
    final data = _decodeJsObject(result);
    if (data == null) {
      return null;
    }
    final parsedPageIndex = _parseJsInt(data['pageIndex']) ?? pageIndex;
    return WebViewPageRange(
      pageIndex: parsedPageIndex,
      startCharIndex: _parseJsInt(data['startChar']),
      endCharIndex: _parseJsInt(data['endChar']),
    );
  }

  Future<void> goToNextPage() {
    return _runJs('MemoReaderApi.nextPage();');
  }

  Future<void> goToPreviousPage() {
    return _runJs('MemoReaderApi.previousPage();');
  }

  Future<void> goToPage(int pageIndex, {bool notify = true}) {
    return _runJs('MemoReaderApi.setPage($pageIndex, ${notify ? 'true' : 'false'});');
  }

  Future<void> goToCharIndex(int charIndex) {
    return _runJs('MemoReaderApi.goToCharIndex($charIndex);');
  }

  Future<int?> findPageForChar(int charIndex) async {
    final result =
        await _runJsReturning('MemoReaderApi.findPageForChar($charIndex);');
    return _parseJsInt(result);
  }

  Future<void> updateLayout() {
    return _runJs('MemoReaderApi.updateLayout();');
  }

  Future<int?> getPageCount() async {
    final result = await _runJsReturning('MemoReaderApi.getPageCount();');
    return _parseJsInt(result);
  }

  Future<int?> getCurrentPage() async {
    final result = await _runJsReturning('MemoReaderApi.getCurrentPage();');
    return _parseJsInt(result);
  }

  Future<void> _runJs(String js) async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    await controller.runJavaScript(js);
  }

  Future<Object?> _runJsReturning(String js) async {
    final controller = _controller;
    if (controller == null) {
      return null;
    }
    return controller.runJavaScriptReturningResult(js);
  }

  static int? _parseJsInt(Object? result) {
    if (result == null) return null;
    if (result is num) return result.toInt();
    if (result is String) return int.tryParse(result);
    return null;
  }

  static String? _parseJsString(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      if (value == 'null' || value == 'undefined') {
        return null;
      }
      if (value.startsWith('"') && value.endsWith('"')) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is String) {
            return decoded;
          }
        } catch (_) {
          return value;
        }
      }
      return value;
    }
    return value.toString();
  }

  static Map<String, dynamic>? _decodeJsObject(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is String) {
      if (value == 'null' || value == 'undefined') {
        return null;
      }
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static String _colorToCss(Color color) {
    final value = color.value;
    final a = (value >> 24) & 0xFF;
    final r = (value >> 16) & 0xFF;
    final g = (value >> 8) & 0xFF;
    final b = value & 0xFF;
    final alpha = (a / 255).toStringAsFixed(3);
    return 'rgba($r, $g, $b, $alpha)';
  }
}

class WebViewReader extends StatefulWidget {
  const WebViewReader({
    super.key,
    required this.html,
    required this.controller,
    required this.onPageChanged,
    required this.onSelectionChanged,
    required this.onSelectionAction,
    required this.onTapAction,
  });

  final String html;
  final WebViewReaderController controller;
  final ValueChanged<WebViewPageUpdate> onPageChanged;
  final void Function(WebViewSelection? selection, VoidCallback clearSelection)
      onSelectionChanged;
  final ValueChanged<String> onSelectionAction;
  final ValueChanged<String> onTapAction;

  @override
  State<WebViewReader> createState() => _WebViewReaderState();
}

class _WebViewReaderState extends State<WebViewReader> {
  late final WebViewController _webViewController;

  @override
  void initState() {
    super.initState();
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    // setBackgroundColor triggers setOpaque() internally; not implemented on macOS.
    // Skip on macOS to avoid UnimplementedError. iOS/Android keep transparent background.
    if (!_isMacOS) {
      _webViewController.setBackgroundColor(Colors.transparent);
    }
    _webViewController
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            // The JS side will emit a ready message when layout is complete.
          },
        ),
      )
      ..addJavaScriptChannel(
        'MemoReader',
        onMessageReceived: _handleMessage,
      );
    widget.controller.attach(_webViewController);
    _loadHtml(widget.html);
  }

  @override
  void didUpdateWidget(WebViewReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _loadHtml(widget.html);
    }
  }

  Future<void> _loadHtml(String html) async {
    await _webViewController.loadHtmlString(html);
  }

  void _handleMessage(JavaScriptMessage message) {
    final data = _decodeMessage(message.message);
    if (data == null) {
      return;
    }
    final type = data['type'];
    if (type == 'ready') {
      widget.controller.markReady();
      final pageIndex = _toInt(data['pageIndex']) ?? 0;
      final pageCount = _toInt(data['pageCount']) ?? 0;
      final totalChars = _toInt(data['totalChars']) ?? 0;
      final startChar = _toInt(data['startChar']);
      final endChar = _toInt(data['endChar']);
      widget.onPageChanged(
        WebViewPageUpdate(
          pageIndex: pageIndex,
          pageCount: pageCount,
          totalChars: totalChars,
          startCharIndex: startChar,
          endCharIndex: endChar,
        ),
      );
      return;
    }
    if (type == 'pageChanged') {
      final pageIndex = _toInt(data['pageIndex']) ?? 0;
      final pageCount = _toInt(data['pageCount']) ?? 0;
      final totalChars = _toInt(data['totalChars']) ?? 0;
      final startChar = _toInt(data['startChar']);
      final endChar = _toInt(data['endChar']);
      widget.onPageChanged(
        WebViewPageUpdate(
          pageIndex: pageIndex,
          pageCount: pageCount,
          totalChars: totalChars,
          startCharIndex: startChar,
          endCharIndex: endChar,
        ),
      );
      return;
    }
    if (type == 'selectionChanged') {
      final hasSelection = data['hasSelection'] == true;
      WebViewSelection? selection;
      if (hasSelection) {
        final text = data['text'];
        final rect = _parseRect(data['rect']);
        if (text is String && text.trim().isNotEmpty) {
          selection = WebViewSelection(
            text: text,
            rect: rect ?? Rect.zero,
          );
        }
      }
      widget.onSelectionChanged(selection, () {
        unawaited(widget.controller.clearSelection());
      });
      return;
    }
    if (type == 'selectionAction') {
      final text = data['text'];
      if (text is String) {
        widget.onSelectionAction(text);
      }
      return;
    }
    if (type == 'tap') {
      final action = data['action'];
      if (action is String) {
        widget.onTapAction(action);
      }
    }
  }

  Map<String, dynamic>? _decodeMessage(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Map<String, dynamic>? _decodeJsObject(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    if (value is String) {
      if (value == 'null' || value == 'undefined') {
        return null;
      }
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String? _parseJsString(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      if (value == 'null' || value == 'undefined') {
        return null;
      }
      if (value.startsWith('"') && value.endsWith('"')) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is String) {
            return decoded;
          }
        } catch (_) {
          return value;
        }
      }
      return value;
    }
    return value.toString();
  }

  double? _toDouble(dynamic value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Rect? _parseRect(dynamic value) {
    if (value is Map) {
      final left = _toDouble(value['left']);
      final top = _toDouble(value['top']);
      final width = _toDouble(value['width']);
      final height = _toDouble(value['height']);
      if (left != null && top != null && width != null && height != null) {
        return Rect.fromLTWH(left, top, width, height);
      }
      final right = _toDouble(value['right']);
      final bottom = _toDouble(value['bottom']);
      if (left != null && top != null && right != null && bottom != null) {
        return Rect.fromLTRB(left, top, right, bottom);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(
      controller: _webViewController,
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      },
    );
  }
}
