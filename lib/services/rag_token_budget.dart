import 'dart:convert';
import 'dart:math' as math;
import 'package:langchain_tiktoken/langchain_tiktoken.dart';

/// cl100k is exact for text-embedding-3. Other provider tokenizers use a
/// conservative UTF-8 estimate as well; offsets always remain canonical chars.
class RagTokenBudget {
  static final _encoding = getEncoding('cl100k_base');
  static final _counts = <String, int>{};
  static int count(String text, {bool conservative = false}) {
    final tokens = _counts[text] ?? _encoding.encodeOrdinary(text).length;
    if (text.length <= 16000) {
      if (_counts.length >= 512) _counts.remove(_counts.keys.first);
      _counts[text] = tokens;
    }
    return conservative
        ? math.max(tokens, (utf8.encode(text).length / 3).ceil())
        : tokens;
  }
}
