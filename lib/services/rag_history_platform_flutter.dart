import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

Future<String> ragHistoryDirectory() async =>
    (await getApplicationSupportDirectory()).path;
DatabaseFactory get ragHistoryFactory => databaseFactory;
