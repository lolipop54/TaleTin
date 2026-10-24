import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/diagnostics/app_errors.dart';
import '../../domain/models/imported_font.dart';
import '../../domain/services/library_file_gate.dart';
import 'imported_font_parser.dart';

/// 字体和目录一起进入整库备份；写入受同一个文件等待器保护。
/// 候选文件验证、字体解码完成后才替换目录，失败不发布半套字体。
class ImportedFontStore {
  ImportedFontStore(this.directory, this.gate);
  final Directory directory;
  final LibraryFileGate gate;
  static const maxFileBytes = 64 * 1024 * 1024;
  List<ImportedFontFamily> _families = [];
  Map<String, int> _sources = {};
  Map<String, List<String>> _sourceFamilies = {};
  Future<void>? _loading;
  Future<void> _writing = Future.value();
  List<ImportedFontFamily> get families => List.unmodifiable(_families);
  File faceFile(ImportedFontFace face) =>
      File('${directory.path}/${face.fileName}');

  Future<void> load() => _loading ??= _read();
  Future<void> _read() async {
    final file = File('${directory.path}/catalog.json');
    if (!await file.exists()) return;
    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (raw['version'] != 1) throw const FormatException('不支持的导入字体目录版本');
    _families = (raw['families'] as List)
        .map((v) => ImportedFontFamily.fromJson(v as Map<String, dynamic>))
        .toList();
    _sources = (raw['sources'] as Map<String, dynamic>).map((k, v) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(k) ||
          v is! int ||
          v < 1 ||
          v > maxFileBytes) {
        throw const FormatException('导入字体来源信息无效');
      }
      return MapEntry(k, v);
    });
    _sourceFamilies = (raw['sourceFamilies'] as Map<String, dynamic>? ?? {})
        .map((key, value) => MapEntry(key, (value as List).cast<String>()));
    // 兼容尚未记录来源候选的目录。独立字体的源摘要与字形摘要相同。
    for (final family in _families) {
      for (final face in family.faces) {
        if (_sources.containsKey(face.digest)) {
          _sourceFamilies.putIfAbsent(face.digest, () => [family.id]);
        }
      }
    }
  }

  /// 路径不是重复依据；移动、改名后的相同文件也只导入一次。
  Future<Set<String>> findImported(Map<String, int> files) async {
    await load();
    if (_sources.isEmpty) return {};
    final sources = Map<String, int>.of(_sources);
    final sourceFamilies = Map<String, List<String>>.of(_sourceFamilies);
    final familyIds = _families.map((f) => f.id).toSet();
    final available = _families
        .expand((f) => f.faces)
        .map((f) => f.digest)
        .toSet();
    return Isolate.run(() async {
      final imported = <String>{};
      final sizes = sources.values.toSet();
      for (final entry in files.entries) {
        if (!sizes.contains(entry.value)) continue;
        try {
          final digest = (await sha256.bind(File(entry.key).openRead()).first)
              .toString();
          if (sources[digest] != entry.value) continue;
          final references = sourceFamilies[digest];
          if (references != null) {
            if (references.every(familyIds.contains)) imported.add(entry.key);
            continue;
          }
          // TTC 可以只删除其中一个候选；只有集合内所有字体仍在才标为已导入。
          final faces = parseImportedFonts(
            await File(entry.key).readAsBytes(),
            entry.key,
          );
          if (faces.every((f) => available.contains(f.face.digest))) {
            imported.add(entry.key);
          }
        } on FileSystemException {
          /* 扫描后文件可能被移动；仍允许重新选择并报告导入失败。 */
        }
      }
      return imported;
    });
  }

  Future<bool> importFile(
    String path, {
    required Future<void> Function(ImportedFontFamily) prepare,
  }) {
    final operation = _writing.then((_) => _import(path, prepare));
    _writing = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<bool> _import(
    String path,
    Future<void> Function(ImportedFontFamily) prepare,
  ) async {
    final release = await gate.enter();
    final created = <File>[];
    try {
      await load();
      final parsed = await Isolate.run(() async {
        final source = File(path), size = await File(path).length();
        if (size == 0 || size > maxFileBytes) {
          throw const FormatException('字体文件为空或超过 64 MiB');
        }
        // 限量读取，避免扫描后仍在下载的文件无限增长占用内存。
        final builder = BytesBuilder(copy: false);
        await for (final bytes in source.openRead(0, maxFileBytes + 1)) {
          builder.add(bytes);
        }
        final bytes = builder.takeBytes();
        if (bytes.length != size) {
          throw const FormatException('字体文件正在变化，请下载完成后重试');
        }
        final digest = sha256.convert(bytes).toString();
        final name = source.uri.pathSegments.last.replaceFirst(
          RegExp(r'\.[^.]+$'),
          '',
        );
        return (
          digest: digest,
          size: size,
          faces: parseImportedFonts(bytes, name),
        );
      });
      final available = _families
          .expand((f) => f.faces)
          .map((f) => f.digest)
          .toSet();
      final references = _sourceFamilies[parsed.digest];
      final familyIds = _families.map((f) => f.id).toSet();
      if (_sources.containsKey(parsed.digest) &&
          (references != null
              ? references.every(familyIds.contains)
              : parsed.faces.every((f) => available.contains(f.face.digest)))) {
        return false;
      }
      await directory.create(recursive: true);
      final candidate = List<ImportedFontFamily>.of(_families);
      final changed = <String>{};
      final sourceIds = <String>{};
      for (final entry in parsed.faces) {
        final face = entry.face;
        final existing = candidate
            .where((f) => f.faces.any((v) => v.digest == face.digest))
            .toList();
        final standalone = 'gt-import-${face.digest}';
        if (existing.isNotEmpty &&
            !(references?.contains(standalone) == true &&
                !familyIds.contains(standalone))) {
          sourceIds.add(existing.first.id);
          continue;
        }
        final file = faceFile(face);
        // 未被目录引用的同名文件可能来自上次中断的写入，重试时完整覆盖。
        if (existing.isEmpty) {
          created.add(file);
          await file.writeAsBytes(entry.bytes, flush: true);
        }
        // 名称相同、字重互补才合并。同字重的不同版本作为独立候选保留。
        final compatible =
            candidate
                .where(
                  (f) =>
                      f.faces.first.familyName == face.familyName &&
                      !f.faces.any(
                        (v) =>
                            v.italic == face.italic &&
                            v.minWeight <= face.maxWeight &&
                            face.minWeight <= v.maxWeight,
                      ),
                )
                .toList()
              ..sort((a, b) => b.faces.length.compareTo(a.faces.length));
        if (existing.isEmpty &&
            compatible.isNotEmpty &&
            (compatible.length == 1 ||
                compatible[0].faces.length > compatible[1].faces.length)) {
          final previous = compatible.first;
          final faces = [...previous.faces, face];
          final digests = faces.map((f) => f.digest).toList()..sort();
          // 保留旧候选及编号：即使当前使用同名字体，补入 Bold 也不能自动改变画面。
          // 新组合是独立可选项，只有读者主动选择后才使用新增字重。
          final next = ImportedFontFamily(
            id: 'gt-import-${sha256.convert(utf8.encode(digests.join(':')))}',
            name:
                '${face.familyName} · ${faces.map((f) => '${f.minWeight}${f.italic ? '斜体' : ''}').join('/')}',
            faces: faces,
          );
          candidate.add(next);
          changed.add(next.id);
          sourceIds.add(next.id);
        } else {
          final duplicateName = candidate.any(
            (f) => f.faces.first.familyName == face.familyName,
          );
          final next = ImportedFontFamily(
            id: 'gt-import-${face.digest}',
            name: duplicateName
                ? '${face.familyName} · ${face.digest.substring(0, 6)}'
                : face.familyName,
            faces: [face],
          );
          candidate.add(next);
          changed.add(next.id);
          sourceIds.add(next.id);
        }
      }
      for (final family in candidate.where((f) => changed.contains(f.id))) {
        await prepare(family);
      }
      final sources = {..._sources, parsed.digest: parsed.size};
      final sourceFamilies = {
        ..._sourceFamilies,
        parsed.digest: sourceIds.toList(),
      };
      await _saveCatalog(candidate, sources, sourceFamilies);
      _families = candidate;
      _sources = sources;
      _sourceFamilies = sourceFamilies;
      return true;
    } catch (_) {
      for (final file in created) {
        if (await file.exists()) await file.delete();
      }
      rethrow;
    } finally {
      release();
    }
  }

  /// 和导入共用写入队列及备份等待器。先准备设置回退，再移除候选；
  /// 多字重组合可能共用文件，仅删除已无人引用的应用内副本。
  Future<void> removeFamily(
    String id, {
    required Future<void> Function() beforeRemove,
  }) {
    final operation = _writing.then((_) async {
      final release = await gate.enter();
      try {
        await load();
        final removed = _families.where((f) => f.id == id).toList();
        if (removed.isEmpty) return;
        final remaining = _families.where((f) => f.id != id).toList();
        await beforeRemove();
        final sources = remaining.isEmpty ? <String, int>{} : _sources;
        final sourceFamilies = remaining.isEmpty
            ? <String, List<String>>{}
            : _sourceFamilies;
        await _saveCatalog(remaining, sources, sourceFamilies);
        _families = remaining;
        _sources = sources;
        _sourceFamilies = sourceFamilies;
        final retained = remaining
            .expand((f) => f.faces)
            .map((f) => f.digest)
            .toSet();
        for (final face in removed.expand((f) => f.faces)) {
          if (retained.contains(face.digest)) continue;
          try {
            await faceFile(face).delete();
          } on FileSystemException catch (error, stack) {
            // 目录已提交；清理失败不把已删除的候选重新发布。
            AppErrors.report(
              error,
              stack,
              operation: '清理已删除字体文件失败',
              notify: false,
            );
          }
        }
      } finally {
        release();
      }
    });
    _writing = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _saveCatalog(
    List<ImportedFontFamily> families,
    Map<String, int> sources,
    Map<String, List<String>> sourceFamilies,
  ) async {
    final temporary = File('${directory.path}/catalog.json.next');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'families': families.map((f) => f.toJson()).toList(),
        'sources': sources,
        'sourceFamilies': sourceFamilies,
      }),
      flush: true,
    );
    await temporary.rename('${directory.path}/catalog.json');
  }

  /// 备份在暂存目录验证字体文件与清单，正式数据替换前拒绝缺失或损坏。
  Future<void> validate() async {
    await load();
    for (final family in _families) {
      for (final face in family.faces) {
        final file = faceFile(face);
        if (!await file.exists() ||
            (await sha256.bind(file.openRead()).first).toString() !=
                face.digest) {
          throw const FormatException('导入字体文件缺失或校验失败');
        }
      }
    }
  }
}
