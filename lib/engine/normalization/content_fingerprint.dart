import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../../domain/models/book_document.dart';

/// 同一份不可变正文只计算一次。仓库重新解码出相同正文时仍可复用原排版，
/// 不能把“Dart 对象换了”当成“书的内容换了”，也不能仅凭书号猜测相同。
abstract final class ContentFingerprint {
  static final _digests = Expando<Future<String>>();
  static Future<String> of(ChapterContent content) => _digests[content] ??=
      content.blocks.length <= 128 && content.textLength <= 8192
      ? Future.value(_digest(content))
      : Isolate.run(() => _digest(content));

  static String _digest(ChapterContent content) =>
      sha256.convert(utf8.encode(jsonEncode(content.toJson()))).toString();
}
