import 'dart:ffi';
import 'dart:io';

DynamicLibrary openVectorLibrary() {
  final override = Platform.environment['MEMOREADER_VEC_LIBRARY'];
  if (override != null) return DynamicLibrary.open(override);
  if (Platform.isIOS || Platform.isMacOS) {
    return DynamicLibrary.open('sqlite_vec.framework/sqlite_vec');
  }
  return DynamicLibrary.open(
    Platform.isWindows ? 'sqlite_vec.dll' : 'libsqlite_vec.so',
  );
}
