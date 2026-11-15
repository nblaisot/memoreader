import 'dart:io';
import 'dart:ffi';
import 'package:sqlite3/open.dart';
import 'package:memoreader_sqlite_vec/memoreader_sqlite_vec.dart';
import 'package:sqlite3/sqlite3.dart' as native;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Runs once in the persistent sqflite FFI worker, before opening connections.
/// Registers the bundled entry point; never enables SQL load_extension().
void initializeRagSqlite() {
  final library = Platform.environment['MEMOREADER_SQLITE_LIBRARY'];
  if (library != null) open.overrideForAll(() => DynamicLibrary.open(library));
  native.sqlite3.ensureExtensionLoaded(
    native.SqliteExtension.inLibrary(openVectorLibrary(), 'sqlite3_vec_init'),
  );
}

final ragDatabaseFactory = createDatabaseFactoryFfi(
  ffiInit: initializeRagSqlite,
);
