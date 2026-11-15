import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'embedding_scheduler.dart';

class SqliteEmbeddingThrottleStore implements EmbeddingThrottleStore {
  SqliteEmbeddingThrottleStore(this.db);
  final Database db;
  static Future<void> create(DatabaseExecutor db) => db.execute(
    'CREATE TABLE IF NOT EXISTS rag_embedding_throttle(bucket TEXT PRIMARY KEY, state TEXT NOT NULL)',
  );
  @override
  Future<T> access<T>(String bucket, T Function(Map<String, dynamic>) update) =>
      db.transaction((txn) async {
        final rows = await txn.query(
          'rag_embedding_throttle',
          where: 'bucket = ?',
          whereArgs: [bucket],
        );
        final state = rows.isEmpty
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(
                jsonDecode(rows.first['state'] as String) as Map,
              );
        final result = update(state);
        await txn.insert('rag_embedding_throttle', {
          'bucket': bucket,
          'state': jsonEncode(state),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return result;
      });
}
