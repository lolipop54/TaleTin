// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'src/third_party/scan.g.dart';

/// 只在后台调用。首次调用会加载词典，之后各 isolate 共用 Rust 里的词典。
({int start, int end})? chineseWordAt(String text, int hit) => using((arena) {
  final input = arena<Uint16>(text.length);
  input.asTypedList(text.length).setAll(0, text.codeUnits);
  final bounds = arena<Uint32>(2);
  if (gt_chinese_word_at(input, text.length, hit, bounds) == 0) return null;
  return (start: bounds[0], end: bounds[1]);
});
