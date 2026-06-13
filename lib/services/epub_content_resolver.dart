import 'package:epubx/epubx.dart';

/// A navigable chapter entry derived from the EPUB table of contents.
class EpubChapterNavEntry {
  const EpubChapterNavEntry({required this.index, required this.title});

  final int index;
  final String title;
}

/// One readable HTML section in spine (or fallback) order.
class EpubReaderSection {
  const EpubReaderSection({
    required this.sectionIndex,
    required this.chapterIndex,
    required this.html,
    required this.contentFileKey,
    this.chapterTitle,
    this.isChapterStart = false,
    this.pageBreakBefore = false,
  });

  final int sectionIndex;
  final int chapterIndex;
  final String html;
  final String contentFileKey;
  final String? chapterTitle;
  final bool isChapterStart;
  final bool pageBreakBefore;
}

/// Ordered reader sections plus chapter navigation metadata.
class EpubContentResolution {
  const EpubContentResolution({
    required this.sections,
    required this.chapters,
  });

  final List<EpubReaderSection> sections;
  final List<EpubChapterNavEntry> chapters;
}

/// Resolves EPUB content for the reader using spine order and TOC landmarks.
class EpubContentResolver {
  EpubContentResolver._();

  /// Builds the ordered list of readable sections for an [EpubBook].
  static EpubContentResolution resolve(EpubBook epub) {
    final htmlFiles = epub.Content?.Html ?? const <String, EpubTextContentFile>{};
    if (htmlFiles.isEmpty) {
      return const EpubContentResolution(sections: [], chapters: []);
    }

    final flatChapters = _flattenChapters(epub.Chapters ?? const <EpubChapter>[]);
    final htmlKeySet = htmlFiles.keys.toSet();
    final landmarks = _buildChapterLandmarks(flatChapters, htmlKeySet);
    final navEntries = landmarks.values
        .map(
          (landmark) => EpubChapterNavEntry(
            index: landmark.navIndex,
            title: landmark.title,
          ),
        )
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    final orderedKeys = _resolveOrderedHtmlKeys(
      epub: epub,
      htmlFiles: htmlFiles,
      flatChapters: flatChapters,
      htmlKeySet: htmlKeySet,
    );

    final rawSections = <_RawSection>[];
    var currentChapterIndex = 0;

    for (final key in orderedKeys) {
      final html = htmlFiles[key]?.Content ?? '';
      if (html.isEmpty) {
        continue;
      }

      final landmark = landmarks[key];
      if (landmark != null) {
        currentChapterIndex = landmark.navIndex;
        rawSections.add(
          _RawSection(
            key: key,
            html: html,
            chapterIndex: currentChapterIndex,
            chapterTitle: landmark.title,
            isChapterStart: true,
          ),
        );
      } else {
        rawSections.add(
          _RawSection(
            key: key,
            html: html,
            chapterIndex: currentChapterIndex,
            isChapterStart: false,
          ),
        );
      }
    }

    final sections = _applyPageBreaks(rawSections);
    return EpubContentResolution(sections: sections, chapters: navEntries);
  }

  static List<EpubReaderSection> _applyPageBreaks(List<_RawSection> rawSections) {
    final sections = <EpubReaderSection>[];

    for (var i = 0; i < rawSections.length; i++) {
      final item = rawSections[i];
      final pageBreakBefore = sections.isNotEmpty && item.isChapterStart;

      sections.add(
        EpubReaderSection(
          sectionIndex: sections.length,
          chapterIndex: item.chapterIndex,
          html: item.html,
          contentFileKey: item.key,
          chapterTitle: item.isChapterStart ? item.chapterTitle : null,
          isChapterStart: item.isChapterStart,
          pageBreakBefore: pageBreakBefore,
        ),
      );
    }

    return sections;
  }

  static List<String> _resolveOrderedHtmlKeys({
    required EpubBook epub,
    required Map<String, EpubTextContentFile> htmlFiles,
    required List<EpubChapter> flatChapters,
    required Set<String> htmlKeySet,
  }) {
    final spineKeys = _resolveSpineHtmlKeys(epub, htmlKeySet);
    if (spineKeys.isNotEmpty) {
      return spineKeys;
    }

    final orderedKeys = <String>[];
    for (final chapter in flatChapters) {
      final fileName = chapter.ContentFileName;
      if (fileName == null) {
        continue;
      }
      final matched = _matchHtmlKey(fileName, htmlKeySet);
      if (matched != null && !orderedKeys.contains(matched)) {
        orderedKeys.add(matched);
      }
    }

    final remaining = htmlFiles.keys.where((key) => !orderedKeys.contains(key)).toList()
      ..sort();
    orderedKeys.addAll(remaining);
    return orderedKeys;
  }

  static List<String> _resolveSpineHtmlKeys(
    EpubBook epub,
    Set<String> htmlKeySet,
  ) {
    final spineItems = epub.Schema?.Package?.Spine?.Items;
    final manifestItems = epub.Schema?.Package?.Manifest?.Items;
    if (spineItems == null ||
        spineItems.isEmpty ||
        manifestItems == null ||
        manifestItems.isEmpty) {
      return const [];
    }

    final idToHref = <String, String>{};
    for (final item in manifestItems) {
      final id = item.Id;
      final href = item.Href;
      if (id != null && href != null) {
        idToHref[id] = Uri.decodeFull(href);
      }
    }

    final keys = <String>[];
    for (final ref in spineItems) {
      if (ref.IsLinear == false) {
        continue;
      }
      final href = idToHref[ref.IdRef];
      if (href == null) {
        continue;
      }
      final key = _matchHtmlKey(href, htmlKeySet);
      if (key != null) {
        keys.add(key);
      }
    }
    return keys;
  }

  static Map<String, _ChapterLandmark> _buildChapterLandmarks(
    List<EpubChapter> flatChapters,
    Set<String> htmlKeySet,
  ) {
    final landmarks = <String, _ChapterLandmark>{};
    var navIndex = 0;

    for (final chapter in flatChapters) {
      final html = chapter.HtmlContent ?? '';
      final fileName = chapter.ContentFileName;
      if (fileName == null || html.isEmpty) {
        continue;
      }

      final key = _matchHtmlKey(fileName, htmlKeySet) ?? _normalizePath(fileName);
      final title = chapter.Title?.trim().isNotEmpty == true
          ? chapter.Title!.trim()
          : 'Chapitre ${navIndex + 1}';

      landmarks[key] = _ChapterLandmark(navIndex: navIndex, title: title);
      navIndex++;
    }

    return landmarks;
  }

  static List<EpubChapter> _flattenChapters(List<EpubChapter> chapters) {
    final result = <EpubChapter>[];
    for (final chapter in chapters) {
      result.add(chapter);
      final subChapters = chapter.SubChapters;
      if (subChapters != null && subChapters.isNotEmpty) {
        result.addAll(_flattenChapters(subChapters));
      }
    }
    return result;
  }

  static String? _matchHtmlKey(String href, Set<String> htmlKeys) {
    if (htmlKeys.contains(href)) {
      return href;
    }

    final normalizedHref = _normalizePath(href);
    for (final key in htmlKeys) {
      if (_normalizePath(key) == normalizedHref) {
        return key;
      }
      if (_basename(key) == _basename(href)) {
        return key;
      }
    }
    return null;
  }

  static String _normalizePath(String path) {
    return path.replaceAll('\\', '/').split('#').first.trim();
  }

  static String _basename(String path) {
    final normalized = _normalizePath(path);
    final slashIndex = normalized.lastIndexOf('/');
    return slashIndex >= 0 ? normalized.substring(slashIndex + 1) : normalized;
  }
}

class _ChapterLandmark {
  const _ChapterLandmark({required this.navIndex, required this.title});

  final int navIndex;
  final String title;
}

class _RawSection {
  const _RawSection({
    required this.key,
    required this.html,
    required this.chapterIndex,
    required this.isChapterStart,
    this.chapterTitle,
  });

  final String key;
  final String html;
  final int chapterIndex;
  final String? chapterTitle;
  final bool isChapterStart;
}
