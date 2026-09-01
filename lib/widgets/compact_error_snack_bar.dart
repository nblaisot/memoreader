import 'package:flutter/material.dart';

SnackBar compactErrorSnackBar(String message) {
  return SnackBar(
    content: Row(
      children: [
        const Icon(Icons.error_outline, color: Colors.white, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ],
    ),
    backgroundColor: Colors.red.shade700,
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    duration: const Duration(seconds: 4),
  );
}

void showCompactErrorSnackBar(
  ScaffoldMessengerState messenger,
  String message,
) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(compactErrorSnackBar(message));
}
