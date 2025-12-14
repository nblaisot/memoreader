import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
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

  void initialize() {
    // For sharing or opening file coming from outside the app while the app is in the memory
    _intentDataStreamSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen((List<SharedMediaFile> value) {
      _handleSharedFiles(value);
    }, onError: (err) {
      debugPrint("getIntentDataStream error: $err");
    });

    // For sharing or opening file coming from outside the app while the app is closed
    ReceiveSharingIntent.instance
        .getInitialMedia()
        .then((List<SharedMediaFile> value) {
      _handleSharedFiles(value);
      ReceiveSharingIntent.instance.reset();
    });
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> files) async {
    if (files.isEmpty) return;

    for (final file in files) {
      if (file.path.toLowerCase().endsWith('.epub')) {
        try {
          debugPrint('Processing shared file: ${file.path}');
          final importedBook = await _bookService.importEpub(File(file.path));
          debugPrint('Imported (or found existing) book: ${importedBook.title}');
          _bookImportedController.add(importedBook);
        } catch (e) {
          debugPrint('Error importing shared file: $e');
        }
      }
    }
  }

  void dispose() {
    _intentDataStreamSubscription?.cancel();
    _bookImportedController.close();
  }
}
