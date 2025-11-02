import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:epubx/epubx.dart';
import '../models/book.dart';
import '../models/chapter.dart';
import 'book_service.dart';
import '../widgets/reader_helpers.dart';

/// Service for loading book content from different formats
/// 
/// Handles EPUB and TXT files and converts them into a unified
/// List<Chapter> format for the reader screen
class BookLoaderService {
  final BookService _bookService;

  BookLoaderService(this._bookService);

  /// Load book content and return chapters
  /// 
  /// Automatically detects the book format and loads content accordingly.
  /// EPUB files use the existing parser, while TXT files are converted
  /// to HTML format for consistent pagination.
  Future<List<Chapter>> loadBookContent(Book book) async {
    switch (book.format) {
      case 'epub':
        return await _loadEpubContent(book);
      case 'txt':
        return await _loadTxtContent(book);
      default:
        throw Exception('Unsupported book format: ${book.format}');
    }
  }

  /// Load EPUB content using existing parser
  Future<List<Chapter>> _loadEpubContent(Book book) async {
    try {
      final epub = await _bookService.loadEpubBook(book.filePath);
      return ReaderHelpers.parseChapters(epub);
    } catch (e) {
      throw Exception('Failed to load EPUB content: $e');
    }
  }

  /// Load TXT content and convert to chapters
  /// 
  /// Reads the entire TXT file and divides it into logical chapters
  /// based on patterns like "Chapter", "CHAPTER", "Part", etc.
  Future<List<Chapter>> _loadTxtContent(Book book) async {
    try {
      final file = File(book.filePath);
      final content = await file.readAsString(encoding: utf8);
      
      if (content.trim().isEmpty) {
        return [Chapter(
          index: 0,
          title: book.title,
          htmlContent: '<p>No content found.</p>',
        )];
      }
      
      // Try to detect chapters by patterns
      final chapterPattern = RegExp(
        r'(?i)^(chapter|chapitre|part|partie|section)\s+\d+.*?(?=\n|$)',
        multiline: true,
      );
      
      final matches = chapterPattern.allMatches(content);
      
      if (matches.isEmpty) {
        // No chapters detected, create a single chapter with all content
        final htmlContent = _textToHtml(content);
        return [Chapter(
          index: 0,
          title: book.title,
          htmlContent: htmlContent,
        )];
      }
      
      // Divide by detected chapters
      final chapters = <Chapter>[];
      int chapterIndex = 0;
      int start = 0;
      
      for (final match in matches) {
        // Add content before this chapter (if any)
        if (match.start > start) {
          final preChapterText = content.substring(start, match.start);
          if (preChapterText.trim().isNotEmpty) {
            final htmlContent = _textToHtml(preChapterText);
            chapters.add(Chapter(
              index: chapterIndex++,
              title: chapterIndex == 1 ? book.title : 'Section $chapterIndex',
              htmlContent: htmlContent,
            ));
          }
        }
        
        // Extract chapter title
        final chapterTitle = match.group(0)?.trim() ?? 'Chapter ${chapterIndex + 1}';
        
        // Find end of this chapter (start of next or end of content)
        final nextMatch = matches.skipWhile((m) => m.start <= match.start).firstOrNull;
        final chapterEnd = nextMatch?.start ?? content.length;
        
        final chapterText = content.substring(match.start, chapterEnd);
        final htmlContent = _textToHtml(chapterText);
        
        chapters.add(Chapter(
          index: chapterIndex++,
          title: chapterTitle,
          htmlContent: htmlContent,
        ));
        
        start = chapterEnd;
      }
      
      // Add remaining content after last chapter
      if (start < content.length) {
        final remainingText = content.substring(start);
        if (remainingText.trim().isNotEmpty) {
          final htmlContent = _textToHtml(remainingText);
          chapters.add(Chapter(
            index: chapterIndex,
            title: 'Appendix',
            htmlContent: htmlContent,
          ));
        }
      }
      
      return chapters.isEmpty 
          ? [Chapter(
              index: 0,
              title: book.title,
              htmlContent: _textToHtml(content),
            )]
          : chapters;
    } catch (e) {
      throw Exception('Failed to load TXT content: $e');
    }
  }


  /// Convert plain text to HTML format
  /// 
  /// Divides text by paragraphs (double newlines) and wraps each paragraph
  /// in <p> tags. Preserves single newlines within paragraphs using <br>.
  String _textToHtml(String text) {
    // Clean text
    text = text.trim();
    
    if (text.isEmpty) {
      return '<p>No content.</p>';
    }
    
    // Split by paragraphs (double newlines or more)
    final paragraphs = text.split(RegExp(r'\n\s*\n'));
    
    // Wrap each paragraph in <p> tags and convert single newlines to <br>
    final htmlParagraphs = paragraphs
        .where((p) => p.trim().isNotEmpty)
        .map((p) {
          final cleaned = p.trim();
          // Convert single newlines to <br>
          final withBreaks = cleaned.replaceAll('\n', '<br>');
          return '<p>$withBreaks</p>';
        })
        .join('\n');
    
    return htmlParagraphs.isEmpty ? '<p>No content.</p>' : htmlParagraphs;
  }
}
