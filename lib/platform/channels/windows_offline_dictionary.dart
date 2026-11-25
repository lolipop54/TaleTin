import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

// 使用与生成词库时相同的 Unicode NFC，例如 e 加组合重音与 é 查同一词条。
final _normalizeString = DynamicLibrary.open('normaliz.dll')
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf16>, Int32, Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, int, Pointer<Utf16>, int)
    >('NormalizeString');

String _key(String text) {
  final spaced = text
      .replaceAll(RegExp(r'[\s\p{Z}]+', unicode: true), ' ')
      .replaceAll(RegExp('[’‘]'), "'")
      .replaceAll(RegExp('[‐‑]'), '-')
      .trim();
  if (spaced.isEmpty) return '';
  return using((arena) {
    final input = spaced.toNativeUtf16(allocator: arena);
    const nfc = 1;
    final capacity = _normalizeString(nfc, input, spaced.length, nullptr, 0);
    if (capacity <= 0) return spaced;
    final output = arena<Uint16>(capacity).cast<Utf16>();
    final length = _normalizeString(
      nfc,
      input,
      spaced.length,
      output,
      capacity,
    );
    return length > 0 ? output.toDartString(length: length) : spaced;
  });
}

/// 在查词专用的后台 isolate 中执行。安装版和便携版由调用方传入各自的缓存。
Future<List<String>> lookupWindowsDictionary(
  ({String term, String assets, String cache}) request,
) async {
  final key = _key(request.term);
  if (key.isEmpty || key.runes.length > 96) return [];
  final chinese = key.runes.any(
    (c) =>
        (c >= 0x3400 && c <= 0x4dbf) ||
        (c >= 0x4e00 && c <= 0x9fff) ||
        (c >= 0xf900 && c <= 0xfaff) ||
        (c >= 0x20000 && c <= 0x33fff),
  );
  final language = chinese ? 'chinese' : 'english';
  final name = '$language-offline-20261111-v1.sqlite';
  final file = File(p.join(request.cache, name));
  if (!await file.exists()) {
    await file.parent.create(recursive: true);
    // 独立临时目录使两份程序同时首次查词时也不会写入同一半成品。
    final staging = await file.parent.createTemp('.extract-');
    try {
      final part = File(p.join(staging.path, name));
      final output = part.openWrite();
      try {
        await output.addStream(
          File(p.join(request.assets, '$name.gz'))
              .openRead()
              .transform(gzip.decoder),
        );
      } finally {
        await output.close();
      }
      try {
        await part.rename(file.path);
      } on FileSystemException {
        if (!await file.exists()) rethrow;
      }
    } finally {
      await staging.delete(recursive: true);
    }
  }
  final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
  try {
    List<String> query(String term) => [
      for (final row in db.select(
        '''
        SELECT e.payload FROM lookup l JOIN entry e ON e.id=l.entry
        WHERE l.key=?1 AND l.priority=(SELECT MIN(priority) FROM lookup WHERE key=?1)
        ORDER BY e.word,e.id
      ''',
        [term],
      ))
        row['payload'] as String,
    ];
    final exact = query(key);
    final lower = key.toLowerCase();
    return exact.isEmpty && key != lower ? query(lower) : exact;
  } finally {
    db.close();
  }
}
