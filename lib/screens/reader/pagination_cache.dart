import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Serializable snapshot of the pagination cursor, used to resume lazy pagination
/// after loading cached pages from disk.
@immutable
class PaginationCursorSnapshot {
  const PaginationCursorSnapshot({
    required this.blockIndex,
    required this.globalCharIndex,
    required this.globalWordIndex,
    this.textState,
  });

  factory PaginationCursorSnapshot.fromJson(Map<String, dynamic> json) {
    return PaginationCursorSnapshot(
      blockIndex: json['blockIndex'] as int,
      globalCharIndex: json['globalCharIndex'] as int,
      globalWordIndex: json['globalWordIndex'] as int,
      textState: json['textState'] != null
          ? TextCursorSnapshot.fromJson(
              json['textState'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  final int blockIndex;
  final int globalCharIndex;
  final int globalWordIndex;
  final TextCursorSnapshot? textState;

  Map<String, dynamic> toJson() {
    return {
      'blockIndex': blockIndex,
      'globalCharIndex': globalCharIndex,
      'globalWordIndex': globalWordIndex,
      if (textState != null) 'textState': textState!.toJson(),
    };
  }
}

/// Serializable snapshot of the text pagination state within a block.
@immutable
class TextCursorSnapshot {
  const TextCursorSnapshot({
    required this.lineIndex,
    required this.textOffset,
    required this.tokenPointer,
  });

  factory TextCursorSnapshot.fromJson(Map<String, dynamic> json) {
    return TextCursorSnapshot(
      lineIndex: json['lineIndex'] as int,
      textOffset: json['textOffset'] as int,
      tokenPointer: json['tokenPointer'] as int,
    );
  }

  final int lineIndex;
  final int textOffset;
  final int tokenPointer;

  Map<String, dynamic> toJson() {
    return {
      'lineIndex': lineIndex,
      'textOffset': textOffset,
      'tokenPointer': tokenPointer,
    };
  }
}

/// Serializable representation of a page block stored in the cache.
@immutable
class CachedPageBlockData {
  const CachedPageBlockData.text({
    required this.text,
    required this.spacingBefore,
    required this.spacingAfter,
    required this.textAlign,
    required this.fontSize,
    required this.height,
    required this.color,
    required this.fontWeight,
    required this.fontStyle,
    required this.fontFamily,
  })  : type = 'text',
        imageHeight = null,
        imageBytes = null;

  const CachedPageBlockData.image({
    required this.spacingBefore,
    required this.spacingAfter,
    required this.imageHeight,
    required this.imageBytes,
  })  : type = 'image',
        text = null,
        textAlign = null,
        fontSize = null,
        height = null,
        color = null,
        fontWeight = null,
        fontStyle = null,
        fontFamily = null;

  factory CachedPageBlockData.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    if (type == 'text') {
      return CachedPageBlockData.text(
        text: json['text'] as String,
        spacingBefore: (json['spacingBefore'] as num).toDouble(),
        spacingAfter: (json['spacingAfter'] as num).toDouble(),
        textAlign: json['textAlign'] as int,
        fontSize: (json['fontSize'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
        color: json['color'] as int?,
        fontWeight: json['fontWeight'] as int?,
        fontStyle: json['fontStyle'] as String?,
        fontFamily: json['fontFamily'] as String?,
      );
    } else {
      return CachedPageBlockData.image(
        spacingBefore: (json['spacingBefore'] as num).toDouble(),
        spacingAfter: (json['spacingAfter'] as num).toDouble(),
        imageHeight: (json['imageHeight'] as num).toDouble(),
        imageBytes: base64Decode(json['imageBytes'] as String),
      );
    }
  }

  final String type;
  final String? text;
  final double spacingBefore;
  final double spacingAfter;
  final int? textAlign;
  final double? fontSize;
  final double? height;
  final int? color;
  final int? fontWeight;
  final String? fontStyle;
  final String? fontFamily;
  final double? imageHeight;
  final List<int>? imageBytes;

  Map<String, dynamic> toJson() {
    if (type == 'text') {
      return {
        'type': type,
        'text': text,
        'spacingBefore': spacingBefore,
        'spacingAfter': spacingAfter,
        'textAlign': textAlign,
        'fontSize': fontSize,
        'height': height,
        'color': color,
        'fontWeight': fontWeight,
        'fontStyle': fontStyle,
        'fontFamily': fontFamily,
      };
    }
    return {
      'type': type,
      'spacingBefore': spacingBefore,
      'spacingAfter': spacingAfter,
      'imageHeight': imageHeight,
      'imageBytes': base64Encode(imageBytes ?? <int>[]),
    };
  }
}

/// Serializable representation of a cached page.
@immutable
class CachedPageData {
  const CachedPageData({
    required this.chapterIndex,
    required this.startWordIndex,
    required this.endWordIndex,
    required this.startCharIndex,
    required this.endCharIndex,
    required this.blocks,
  });

  factory CachedPageData.fromJson(Map<String, dynamic> json) {
    final blocks = (json['blocks'] as List<dynamic>)
        .map((blockJson) =>
            CachedPageBlockData.fromJson(blockJson as Map<String, dynamic>))
        .toList(growable: false);
    return CachedPageData(
      chapterIndex: json['chapterIndex'] as int,
      startWordIndex: json['startWordIndex'] as int,
      endWordIndex: json['endWordIndex'] as int,
      startCharIndex: json['startCharIndex'] as int,
      endCharIndex: json['endCharIndex'] as int,
      blocks: blocks,
    );
  }

  final int chapterIndex;
  final int startWordIndex;
  final int endWordIndex;
  final int startCharIndex;
  final int endCharIndex;
  final List<CachedPageBlockData> blocks;

  Map<String, dynamic> toJson() {
    return {
      'chapterIndex': chapterIndex,
      'startWordIndex': startWordIndex,
      'endWordIndex': endWordIndex,
      'startCharIndex': startCharIndex,
      'endCharIndex': endCharIndex,
      'blocks': blocks.map((block) => block.toJson()).toList(growable: false),
    };
  }
}

/// Container for cached pagination data for a given layout configuration.
@immutable
class PaginationCacheEntry {
  const PaginationCacheEntry({
    required this.pages,
    required this.isComplete,
    required this.totalCharacters,
    this.cursor,
  });

  factory PaginationCacheEntry.fromJson(Map<String, dynamic> json) {
    final pages = (json['pages'] as List<dynamic>)
        .map((pageJson) => CachedPageData.fromJson(pageJson as Map<String, dynamic>))
        .toList(growable: false);
    return PaginationCacheEntry(
      pages: pages,
      isComplete: json['isComplete'] as bool,
      totalCharacters: json['totalCharacters'] as int,
      cursor: json['cursor'] != null
          ? PaginationCursorSnapshot.fromJson(
              json['cursor'] as Map<String, dynamic>,
            )
          : null,
    );
  }

  final List<CachedPageData> pages;
  final bool isComplete;
  final int totalCharacters;
  final PaginationCursorSnapshot? cursor;

  Map<String, dynamic> toJson() {
    return {
      'pages': pages.map((page) => page.toJson()).toList(growable: false),
      'isComplete': isComplete,
      'totalCharacters': totalCharacters,
      if (cursor != null) 'cursor': cursor!.toJson(),
    };
  }
}

/// Persists pagination caches keyed by layout parameters and book identifier.
class PaginationCacheManager {
  const PaginationCacheManager();

  Future<String> _getBaseDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final cacheDir = Directory(p.join(dir.path, 'pagination_cache'));
    if (!await cacheDir.exists()) {
      await cacheDir.create(recursive: true);
    }
    return cacheDir.path;
  }

  Future<File> _resolveFile(String bookId, String layoutKey) async {
    final baseDir = await _getBaseDirectory();
    final bookDir = Directory(p.join(baseDir, bookId));
    if (!await bookDir.exists()) {
      await bookDir.create(recursive: true);
    }
    final fileName = '$layoutKey.json';
    return File(p.join(bookDir.path, fileName));
  }

  Future<PaginationCacheEntry?> load(String bookId, String layoutKey) async {
    try {
      final file = await _resolveFile(bookId, layoutKey);
      if (!await file.exists()) {
        return null;
      }
      final jsonText = await file.readAsString();
      final data = jsonDecode(jsonText) as Map<String, dynamic>;
      return PaginationCacheEntry.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(
    String bookId,
    String layoutKey,
    PaginationCacheEntry entry,
  ) async {
    try {
      final file = await _resolveFile(bookId, layoutKey);
      final tmpFile = File('${file.path}.tmp');
      await tmpFile.writeAsString(jsonEncode(entry.toJson()));
      await tmpFile.rename(file.path);
    } catch (_) {
      // Ignore cache write failures; cache is best-effort.
    }
  }
}
