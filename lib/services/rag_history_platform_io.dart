import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<String> ragHistoryDirectory() async => Directory.systemTemp.path;
DatabaseFactory get ragHistoryFactory => databaseFactoryFfi;
