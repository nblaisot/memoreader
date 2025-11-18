import 'package:flutter/material.dart';

/// Base class for renderable HTML-derived blocks.
abstract class HtmlBlock {
  HtmlBlock({
    this.spacingBefore = 0,
    this.spacingAfter = 0,
  });

  double spacingBefore;
  double spacingAfter;

  /// Cached measurement for the current layout.
  double? measuredHeight;

  InlineSpan toInlineSpan(TextStyle baseStyle);
}

class ParagraphBlock extends HtmlBlock {
  ParagraphBlock({
    required this.text,
    this.alignment = TextAlign.start,
    super.spacingBefore = 8,
    super.spacingAfter = 12,
  });

  final String text;
  final TextAlign alignment;

  @override
  InlineSpan toInlineSpan(TextStyle baseStyle) {
    return TextSpan(text: text, style: baseStyle, children: const []);
  }
}

class HeaderBlock extends HtmlBlock {
  HeaderBlock({
    required this.text,
    required this.level,
    this.alignment = TextAlign.center,
    super.spacingBefore = 18,
    super.spacingAfter = 16,
  });

  final String text;
  final int level;
  final TextAlign alignment;

  @override
  InlineSpan toInlineSpan(TextStyle baseStyle) {
    final scale = (2.0 - (level * 0.15)).clamp(1.1, 1.6);
    return TextSpan(
      text: text,
      style: baseStyle.copyWith(
        fontSize: (baseStyle.fontSize ?? 16) * scale,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class QuoteBlock extends HtmlBlock {
  QuoteBlock({
    required this.text,
    this.alignment = TextAlign.start,
    super.spacingBefore = 12,
    super.spacingAfter = 12,
  });

  final String text;
  final TextAlign alignment;

  @override
  InlineSpan toInlineSpan(TextStyle baseStyle) {
    return TextSpan(
      text: '“$text”',
      style: baseStyle.copyWith(
        fontStyle: FontStyle.italic,
        color: baseStyle.color?.withOpacity(0.9),
      ),
    );
  }
}

class ImageBlock extends HtmlBlock {
  ImageBlock({
    required this.bytes,
    this.source,
    this.intrinsicWidth,
    this.intrinsicHeight,
    super.spacingBefore = 12,
    super.spacingAfter = 16,
  });

  final List<int> bytes;
  final String? source;
  final double? intrinsicWidth;
  final double? intrinsicHeight;

  @override
  InlineSpan toInlineSpan(TextStyle baseStyle) {
    // Images are rendered as widgets; span is only used for measurement fallback.
    return WidgetSpan(
      child: SizedBox(
        width: intrinsicWidth,
        height: intrinsicHeight,
      ),
    );
  }
}

class ChapterPosition {
  const ChapterPosition({required this.blockIndex});
  final int blockIndex;
}

class PageResult {
  const PageResult({
    required this.blocks,
    required this.startBlockIndex,
    required this.nextBlockIndex,
  });

  final List<HtmlBlock> blocks;
  final int startBlockIndex;
  final int nextBlockIndex;
}
