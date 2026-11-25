import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'src/third_party/scan.g.dart';

/// 返回合法换行点在原字符串里的 UTF-16 偏移，含最后一个字符的结束位置。
Uint32List lineBreakOffsets(String text) {
  if (text.isEmpty) return Uint32List(0);
  return using((arena) {
    final input = arena<Uint16>(text.length);
    input.asTypedList(text.length).setAll(0, text.codeUnits);
    final output = arena<Uint32>(text.length);
    final count = gt_line_breaks(input, text.length, output);
    return Uint32List.fromList(output.asTypedList(count));
  });
}
