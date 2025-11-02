import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

/// Widget that measures the actual rendered height of HTML content
/// 
/// Uses a GlobalKey to measure the rendered height after layout.
class HtmlHeightMeasurer extends StatefulWidget {
  final String htmlContent;
  final TextStyle textStyle;
  final double maxHeight;
  final Function(double)? onHeightMeasured;

  const HtmlHeightMeasurer({
    super.key,
    required this.htmlContent,
    required this.textStyle,
    required this.maxHeight,
    this.onHeightMeasured,
  });

  @override
  State<HtmlHeightMeasurer> createState() => _HtmlHeightMeasurerState();
}

class _HtmlHeightMeasurerState extends State<HtmlHeightMeasurer> {
  final GlobalKey _measureKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureHeight();
    });
  }

  @override
  void didUpdateWidget(HtmlHeightMeasurer oldWidget) {
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
    if (renderBox != null) {
      final height = renderBox.size.height;
      widget.onHeightMeasured?.call(height);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: _measureKey,
      child: HtmlWidget(
        widget.htmlContent,
        textStyle: widget.textStyle,
      ),
    );
  }
}

