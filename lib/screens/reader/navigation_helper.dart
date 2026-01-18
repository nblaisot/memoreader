import 'package:flutter/material.dart';

Future<void> returnToLibrary(
  BuildContext context, {
  required Future<void> Function() openLibrary,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  if (navigator.canPop()) {
    navigator.pop();
    return;
  }
  await openLibrary();
}
