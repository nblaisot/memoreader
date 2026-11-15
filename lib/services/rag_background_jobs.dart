import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'rag_indexing_service.dart';
import 'rag_database_service.dart';

@pragma('vm:entry-point')
void ragBackgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    RagBackgroundJobs.inBackground = true;
    try {
      await RagIndexingService().recover(waitForCompletion: true);
      final waiting = await (await RagDatabaseService().database).rawQuery(
        "SELECT count(*) AS n FROM rag_jobs WHERE state IN ('waiting','preparing')",
      );
      return waiting.first['n'] == 0;
    } catch (_) {
      return false;
    }
  });
}

class RagBackgroundJobs {
  static const identifier = 'com.blaisotbalette.memoreader.rag.prepare';
  static bool inBackground = false;
  static Future<void>? _initializing;
  static Future<void> initialize() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    await (_initializing ??= Workmanager().initialize(ragBackgroundDispatcher));
  }

  static Future<void> schedule({Duration initialDelay = Duration.zero}) async {
    if (inBackground || (!Platform.isAndroid && !Platform.isIOS)) return;
    try {
      await initialize();
      if (Platform.isIOS) {
        await Workmanager().registerProcessingTask(
          identifier,
          identifier,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      } else {
        await Workmanager().registerOneOffTask(
          identifier,
          identifier,
          existingWorkPolicy: ExistingWorkPolicy.keep,
          initialDelay: initialDelay,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      }
    } catch (_) {
      /* Foreground coordinator remains authoritative. */
    }
  }
}
