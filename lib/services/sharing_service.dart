import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:open_file_handler/open_file_handler.dart';
import 'package:memoreader/services/book_service.dart';
import 'package:memoreader/models/book.dart';

class SharingService {
  static final SharingService _instance = SharingService._internal();
  factory SharingService() => _instance;
  SharingService._internal();

  final BookService _bookService = BookService();
  StreamSubscription? _intentDataStreamSubscription;
  
  // Stream controller to notify UI of imports
  final _bookImportedController = StreamController<Book>.broadcast();
  Stream<Book> get onBookImported => _bookImportedController.stream;

  // Store pending initial media for when listener subscribes
  List<SharedMediaFile>? _pendingInitialMedia;
  bool _hasListeners = false;
  
  // Open file handler for "Open with" functionality (iOS/macOS)
  final OpenFileHandler _openFileHandler = OpenFileHandler();
  StreamSubscription? _openFileSubscription;

  void initialize() {
    debugPrint('SharingService: initialize() called');
    
    // Setup stream listener tracking - process pending media when listener subscribes
    _bookImportedController.onListen = () {
      debugPrint('SharingService: onBookImported stream listener subscribed');
      _hasListeners = true;
      // Process pending initial media if any
      if (_pendingInitialMedia != null && _pendingInitialMedia!.isNotEmpty) {
        debugPrint('Processing ${_pendingInitialMedia!.length} pending initial media file(s)');
        _handleSharedFiles(_pendingInitialMedia!);
        _pendingInitialMedia = null;
      }
    };

    // For sharing or opening file coming from outside the app while the app is in the memory
    debugPrint('SharingService: Setting up getMediaStream listener');
    _intentDataStreamSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen((List<SharedMediaFile> value) {
      debugPrint('SharingService: getMediaStream received ${value.length} file(s)');
      if (value.isNotEmpty) {
        for (var file in value) {
          debugPrint('SharingService: Media file path: ${file.path}');
        }
        _handleSharedFiles(value);
      }
    }, onError: (err) {
      debugPrint("SharingService: getMediaStream error: $err");
    });

    // For sharing or opening file coming from outside the app while the app is closed
    debugPrint('SharingService: Calling getInitialMedia()');
    ReceiveSharingIntent.instance
        .getInitialMedia()
        .then((List<SharedMediaFile> value) {
      debugPrint('SharingService: getInitialMedia() returned ${value?.length ?? 0} file(s)');
      if (value != null && value.isNotEmpty) {
        for (var file in value) {
          debugPrint('SharingService: Initial media file path: ${file.path}');
        }
        debugPrint('SharingService: Received ${value.length} initial media file(s)');
        if (_hasListeners) {
          // Process immediately if listener is ready
          _handleSharedFiles(value);
        } else {
          // Store for processing when listener subscribes
          _pendingInitialMedia = value;
          debugPrint('SharingService: Storing ${value.length} initial media file(s) for processing when listener subscribes');
        }
        ReceiveSharingIntent.instance.reset();
      } else {
        debugPrint('SharingService: getInitialMedia() returned empty or null');
        ReceiveSharingIntent.instance.reset();
      }
    }).catchError((err) {
      debugPrint("SharingService: getInitialMedia error: $err");
      ReceiveSharingIntent.instance.reset();
    });
    
    // Setup open_file_handler for "Open with" functionality (iOS/macOS)
    if (Platform.isIOS || Platform.isMacOS) {
      debugPrint('SharingService: Setting up open_file_handler listener');
      _openFileSubscription = _openFileHandler.listen(
        (files) {
          debugPrint('SharingService: open_file_handler received ${files.length} file(s)');
          for (var file in files) {
            debugPrint('SharingService: Open file - name: ${file.name}, path: ${file.path}, uri: ${file.uri}');
            if (file.path != null && file.path!.isNotEmpty) {
              _handleFileUrlDirectly(file.path!);
            } else if (file.uri != null) {
              // Try to extract path from URI
              final uri = Uri.parse(file.uri!);
              if (uri.isScheme('file')) {
                _handleFileUrlDirectly(uri.path);
              }
            }
          }
        },
        onError: (error) {
          debugPrint('SharingService: open_file_handler error: $error');
        },
      );
    }
  }
  
  Future<void> _handleFileUrlDirectly(String filePath) async {
    try {
      debugPrint('SharingService: Processing direct file URL: $filePath');
      final file = File(filePath);
      
      if (!await file.exists()) {
        debugPrint('SharingService: File does not exist at path: $filePath');
        return;
      }
      
      // Check file extension
      final pathLower = filePath.toLowerCase();
      if (!pathLower.endsWith('.epub') && !pathLower.endsWith('.txt')) {
        debugPrint('SharingService: File is not EPUB or TXT: $filePath');
        return;
      }
      
      // Import the file
      Book importedBook;
      if (pathLower.endsWith('.txt')) {
        debugPrint('SharingService: Importing TXT file: $filePath');
        importedBook = await _bookService.importTxt(file);
      } else {
        debugPrint('SharingService: Importing EPUB file: $filePath');
        importedBook = await _bookService.importEpub(file);
      }
      
      debugPrint('SharingService: Successfully imported book: ${importedBook.title} by ${importedBook.author}');
      _bookImportedController.add(importedBook);
    } catch (e, stackTrace) {
      debugPrint('SharingService: ERROR importing file $filePath: $e');
      debugPrint('SharingService: Stack trace: $stackTrace');
    }
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    if (files.isEmpty) {
      debugPrint('No shared files received');
      return;
    }

    debugPrint('Received ${files.length} shared file(s)');

    // CRITICAL FIX: Filter out files with null/empty paths FIRST
    final validFiles = files.where((file) {
      if (file.path == null || file.path!.isEmpty) {
        debugPrint('Skipping file with null/empty path');
        return false;
      }
      return true;
    }).toList();

    if (validFiles.isEmpty) {
      debugPrint('No valid files to process (all paths are null/empty)');
      return;
    }

    debugPrint('Processing ${validFiles.length} valid file(s) out of ${files.length} total');

    for (final file in validFiles) {
      try {
        // Now safe to use file.path - we've validated it's non-null and non-empty
        String normalizedPath = _normalizeFilePath(file.path!);
        debugPrint('Processing file: $normalizedPath');
        
        final fileObj = File(normalizedPath);
        
        // Check if file exists and is readable BEFORE importing
        if (!await fileObj.exists()) {
          debugPrint('ERROR: File does not exist at path: $normalizedPath');
          continue;
        }
        
        // Verify file is readable
        try {
          await fileObj.readAsBytes();
        } catch (e) {
          debugPrint('ERROR: Cannot read file at path $normalizedPath: $e');
          continue;
        }
        
        // Check file extension
        final pathLower = normalizedPath.toLowerCase();
        if (!pathLower.endsWith('.epub') && !pathLower.endsWith('.txt')) {
          debugPrint('Skipping file - not an EPUB or TXT: $normalizedPath');
          continue;
        }
        
        // Determine file type and import accordingly
        Book importedBook;
        if (pathLower.endsWith('.txt')) {
          debugPrint('Importing TXT file: $normalizedPath');
          importedBook = await _bookService.importTxt(fileObj);
        } else {
          debugPrint('Importing EPUB file: $normalizedPath');
          importedBook = await _bookService.importEpub(fileObj);
        }
        
        debugPrint('Successfully imported book: ${importedBook.title} by ${importedBook.author}');
        _bookImportedController.add(importedBook);
      } catch (e, stackTrace) {
        debugPrint('ERROR importing file ${file.path}: $e');
        debugPrint('Stack trace: $stackTrace');
        // Continue processing other files
      }
    }
  }

  /// Normalize file path by removing "file://" prefix and URL decoding if needed
  String _normalizeFilePath(String path) {
    if (path.isEmpty) {
      debugPrint('Warning: Received empty path for normalization');
      return path;
    }
    
    // Remove "file://" prefix if present
    String normalized = path;
    if (normalized.startsWith('file://')) {
      normalized = normalized.substring(7);
      debugPrint('Removed file:// prefix from path');
    }
    
    // URL decode if the path contains encoded characters
    try {
      // Check if the path contains URL-encoded characters (%XX)
      if (normalized.contains('%')) {
        normalized = Uri.decodeComponent(normalized);
        debugPrint('URL decoded path');
      }
    } catch (e) {
      // If URL decoding fails, use the original normalized path
      debugPrint('Warning: Failed to URL decode path: $e');
    }
    
    return normalized;
  }

  void dispose() {
    _intentDataStreamSubscription?.cancel();
    _openFileSubscription?.cancel();
    _bookImportedController.close();
  }
}
