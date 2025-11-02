import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

/// Widget that measures the actual rendered height of HTML content
/// 
/// This widget renders HTML content and measures its actual height
/// using GlobalKey and RenderBox. This allows for accurate dynamic pagination.
class HtmlHeightMeasurerWidget extends StatefulWidget {
  final String htmlContent;
  final TextStyle textStyle;
  final double maxWidth;
  final Function(double) onHeightMeasured;

  const HtmlHeightMeasurerWidget({
    super.key,
    required this.htmlContent,
    required this.textStyle,
    required this.maxWidth,
    required this.onHeightMeasured,
  });

  @override
  State<HtmlHeightMeasurerWidget> createState() => _HtmlHeightMeasurerWidgetState();
}

class _HtmlHeightMeasurerWidgetState extends State<HtmlHeightMeasurerWidget> {
  final GlobalKey _measureKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureHeight();
    });
  }

  @override
  void didUpdateWidget(HtmlHeightMeasurerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.htmlContent != widget.htmlContent ||
        oldWidget.textStyle != widget.textStyle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _measureHeight();
      });
    }
  }

  void _measureHeight() {
    final RenderBox? renderBox = 
        _measureKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      final height = renderBox.size.height;
      widget.onHeightMeasured(height);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: _measureKey,
      width: widget.maxWidth,
      child: HtmlWidget(
        widget.htmlContent,
        textStyle: widget.textStyle,
      ),
    );
  }
}

/// Helper to measure HTML height by rendering it
/// 
/// This uses a one-off render in an overlay to measure actual height.
class HtmlHeightMeasurer {
  /// Measure the actual rendered height of HTML content
  static Future<double> measureHeight({
    required BuildContext context,
    required String htmlContent,
    required TextStyle textStyle,
    required double maxWidth,
  }) async {
    final completer = Completer<double>();
    
    // Use an overlay entry to render and measure
    final overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: -10000, // Render off-screen
        top: -10000,
        child: Material(
          type: MaterialType.transparency,
          child: HtmlHeightMeasurerWidget(
            htmlContent: htmlContent,
            textStyle: textStyle,
            maxWidth: maxWidth,
            onHeightMeasured: (height) {
              completer.complete(height);
            },
          ),
        ),
      ),
    );

    Overlay.of(context).insert(overlayEntry);

    try {
      // Wait a frame for the widget to render
      await Future.delayed(const Duration(milliseconds: 50));
      
      final height = await completer.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          // Fallback: measure with TextPainter
          return _fallbackMeasure(htmlContent, textStyle, maxWidth);
        },
      );
      
      overlayEntry.remove();
      return height;
    } catch (e) {
      overlayEntry.remove();
      return _fallbackMeasure(htmlContent, textStyle, maxWidth);
    }
  }

  /// Fallback measurement using TextPainter
  static double _fallbackMeasure(
    String htmlContent,
    TextStyle textStyle,
    double maxWidth,
  ) {
    try {
      // Parse HTML to get plain text
      final plainText = htmlContent
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      
      if (plainText.isEmpty) return 0.0;
      
      final textPainter = TextPainter(
        text: TextSpan(text: plainText, style: textStyle),
        textDirection: TextDirection.ltr,
        maxLines: null,
      );
      textPainter.layout(maxWidth: maxWidth);
      return textPainter.size.height * 1.15; // Add margin for HTML rendering
    } catch (e) {
      return 0.0;
    }
  }
}

