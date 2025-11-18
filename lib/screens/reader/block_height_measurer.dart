import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'html_blocks.dart';

class BlockHeightMeasurer {
  BlockHeightMeasurer({
    required this.maxWidth,
    required this.pageHeight,
    required this.baseStyle,
    required this.devicePixelRatio,
  });

  final double maxWidth;
  final double pageHeight;
  final TextStyle baseStyle;
  final double devicePixelRatio;

  double measure(HtmlBlock block) {
    if (block.measuredHeight != null) {
      return block.measuredHeight!;
    }

    double height;
    if (block is ImageBlock) {
      height = _measureImage(block);
    } else {
      final painter = TextPainter(
        text: block.toInlineSpan(baseStyle),
        textDirection: TextDirection.ltr,
        maxLines: null,
      )..layout(maxWidth: maxWidth);
      height = painter.height;
    }

    // Align to device pixels for determinism.
    final pixelHeight = (height * devicePixelRatio).ceilToDouble() / devicePixelRatio;
    block.measuredHeight = pixelHeight;
    return pixelHeight;
  }

  double _measureImage(ImageBlock block) {
    final intrinsicWidth = block.intrinsicWidth ?? maxWidth;
    final intrinsicHeight = block.intrinsicHeight ?? (maxWidth * 0.6);
    if (intrinsicWidth <= 0 || intrinsicHeight <= 0) {
      return math.min(pageHeight, maxWidth * 0.6);
    }

    var fittedWidth = math.min(maxWidth, intrinsicWidth);
    var fittedHeight = (fittedWidth / intrinsicWidth) * intrinsicHeight;

    if (fittedHeight > pageHeight) {
      fittedHeight = pageHeight;
      fittedWidth = (fittedHeight / intrinsicHeight) * intrinsicWidth;
      if (fittedWidth > maxWidth) {
        fittedWidth = maxWidth;
        fittedHeight = (fittedWidth / intrinsicWidth) * intrinsicHeight;
      }
    }

    return fittedHeight;
  }
}
