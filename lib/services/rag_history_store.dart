import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show Database, DatabaseExecutor, OpenDatabaseOptions, ConflictAlgorithm;
import 'rag_history_platform_io.dart'
    if (dart.library.ui) 'rag_history_platform_flutter.dart';
import '../models/rag_chunk.dart';

/// Local-only history, deliberately separate from book/sync databases.
class RagHistoryStore {
  RagHistoryStore({this.path});
  static final instance = RagHistoryStore();
  final String? path;
  Future<Database>? _opening;
  Future<void> _pending = Future.value();
  Future<Database> get database => _opening ??= _open();
  Future<Database> _open() async {
    final location =
        path ?? p.join((await ragHistoryDirectory()), 'rag-history.db');
    final db = await ragHistoryFactory.openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys=ON');
        },
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE conversations(id TEXT PRIMARY KEY,updated INTEGER NOT NULL,data TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE turns(id TEXT PRIMARY KEY,conversationId TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,created INTEGER NOT NULL,data TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE events(id INTEGER PRIMARY KEY AUTOINCREMENT,conversationId TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,turnId TEXT NOT NULL,attemptId TEXT NOT NULL,data TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE sources(id TEXT PRIMARY KEY,data TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE turn_sources(turnId TEXT NOT NULL REFERENCES turns(id) ON DELETE CASCADE,sourceId TEXT NOT NULL REFERENCES sources(id),position INTEGER NOT NULL,PRIMARY KEY(turnId,position))',
          );
          await db.execute(
            'CREATE INDEX events_conversation ON events(conversationId,id)',
          );
        },
      ),
    );
    // Only once per process/store initialization: never interrupt a live turn
    // when a second screen opens the same singleton.
    final rows = await db.query('turns');
    for (final row in rows) {
      final data = jsonDecode(row['data'] as String) as Map<String, dynamic>;
      if (data['status'] == 'running') {
        data['status'] = 'interrupted';
        await db.update(
          'turns',
          {'data': jsonEncode(data)},
          where: 'id=?',
          whereArgs: [row['id']],
        );
      }
    }
    return db;
  }

  Future<void> _write(Future<void> Function(Database) action) {
    final next = _pending.then((_) async => action(await database));
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<void> flush() => _pending;

  Future<void> begin(
    String conversationId,
    String turnId,
    Map<String, dynamic> conversation,
    Map<String, dynamic> turn,
  ) => _write((db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((tx) async {
      await tx.insert('conversations', {
        'id': conversationId,
        'updated': now,
        'data': jsonEncode(conversation),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.update(
        'conversations',
        {'updated': now, 'data': jsonEncode(conversation)},
        where: 'id=?',
        whereArgs: [conversationId],
      );
      await tx.insert('turns', {
        'id': turnId,
        'conversationId': conversationId,
        'created': now,
        'data': jsonEncode(turn),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.rawDelete(
        'DELETE FROM conversations WHERE id NOT IN (SELECT id FROM conversations ORDER BY updated DESC,id DESC LIMIT 5)',
      );
      await _gc(tx);
    });
  });

  Future<void> saveTurn(
    String turnId,
    Map<String, dynamic> data,
    List<RagChunk> sources,
  ) => _write((db) async {
    await db.transaction((tx) async {
      await tx.update(
        'turns',
        {'data': jsonEncode(data)},
        where: 'id=?',
        whereArgs: [turnId],
      );
      await tx.delete('turn_sources', where: 'turnId=?', whereArgs: [turnId]);
      for (var i = 0; i < sources.length; i++) {
        final text = jsonEncode(sources[i].toJson());
        final key = sha256.convert(utf8.encode(text)).toString();
        await tx.insert('sources', {
          'id': key,
          'data': text,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        await tx.insert('turn_sources', {
          'turnId': turnId,
          'sourceId': key,
          'position': i,
        });
      }
      await _gc(tx);
    });
  });

  Future<void> event(
    String conversation,
    String turn,
    String attempt,
    String type,
    Map<String, dynamic> data,
  ) => _write((db) async {
    await db.insert('events', {
      'conversationId': conversation,
      'turnId': turn,
      'attemptId': attempt,
      'data': jsonEncode({
        'type': type,
        'utc': DateTime.now().toUtc().toIso8601String(),
        ...sanitize(data),
      }),
    });
  });

  /// Defense in depth: request code supplies only prompts, visible output and
  /// allowlisted response metadata. Never persist arbitrary HTTP envelopes.
  static Map<String, dynamic> sanitize(Map<String, dynamic> data) {
    dynamic clean(dynamic v) {
      if (v is Map)
        return {
          for (final e in v.entries)
            if (!RegExp(
              r'authorization|cookie|api.?key|access.?token|refresh.?token|thinking|reasoning_content',
              caseSensitive: false,
            ).hasMatch(e.key.toString()))
              e.key.toString(): clean(e.value),
        };
      if (v is List) return v.map(clean).toList();
      return v;
    }

    return Map<String, dynamic>.from(clean(data) as Map);
  }

  Future<List<Map<String, dynamic>>> list() async {
    await flush();
    return (await (await database).query(
          'conversations',
          orderBy: 'updated DESC,id DESC',
        ))
        .map(
          (r) => {
            'id': r['id'],
            'updated': r['updated'],
            ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
          },
        )
        .toList();
  }

  Future<List<Map<String, dynamic>>> turns(String conversationId) async {
    await flush();
    final db = await database;
    final rows = await db.query(
      'turns',
      where: 'conversationId=?',
      whereArgs: [conversationId],
      orderBy: 'created,id',
    );
    final result = <Map<String, dynamic>>[];
    for (final r in rows) {
      final sourceRows = await db.rawQuery(
        'SELECT s.data FROM turn_sources x JOIN sources s ON s.id=x.sourceId WHERE x.turnId=? ORDER BY x.position',
        [r['id']],
      );
      result.add({
        'id': r['id'],
        ...jsonDecode(r['data'] as String) as Map<String, dynamic>,
        'sources': sourceRows
            .map((s) => jsonDecode(s['data'] as String))
            .toList(),
      });
    }
    return result;
  }

  static List<RagChunk> decodeSources(Map<String, dynamic> data) =>
      (data['sources'] as List? ?? [])
          .map(
            (s) => RagChunk.fromJson(
              Map<String, dynamic>.from(s as Map),
              Uint8List(0),
            ),
          )
          .toList();
  Future<void> delete(String id) => _write((db) async {
    await db.transaction((tx) async {
      await tx.delete('conversations', where: 'id=?', whereArgs: [id]);
      await _gc(tx);
    });
  });
  static Future<void> _gc(DatabaseExecutor db) async => db.execute(
    'DELETE FROM sources WHERE id NOT IN (SELECT sourceId FROM turn_sources)',
  );
  Future<Map<String, dynamic>> export({String? conversationId}) async {
    final conversations = await list();
    final result = <Map<String, dynamic>>[];
    for (final c in conversations.where(
      (c) => conversationId == null || c['id'] == conversationId,
    )) {
      final id = c['id'] as String;
      final events = await (await database).query(
        'events',
        where: 'conversationId=?',
        whereArgs: [id],
        orderBy: 'id',
      );
      result.add({
        ...c,
        'turns': await turns(id),
        'events': events
            .map(
              (e) => {
                'turnId': e['turnId'],
                'attemptId': e['attemptId'],
                ...jsonDecode(e['data'] as String) as Map<String, dynamic>,
              },
            )
            .toList(),
      });
    }
    return {'version': 1, 'conversations': result};
  }

  Future<void> close() async {
    await flush();
    if (_opening != null) await (await database).close();
    _opening = null;
  }
}
