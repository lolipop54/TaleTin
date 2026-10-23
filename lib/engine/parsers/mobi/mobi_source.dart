import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:direct_read_rust/byte_processing.dart';
import 'package:mobi_native/mobi_native.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../epub/epub_archive.dart';
import 'mobi_rewriter.dart';
import 'mobi_splitter.dart';

const _container = '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';

/// One original MOBI plus compact native/segment recipes; no publication files.
class MobiPublicationSource implements BatchedPublicationEntries {
  MobiPublicationSource._(this.native, this.metadata) {
    _nativeEntries = {for (final entry in native.entries) entry.name: entry};
    _segments = (metadata['segments'] as Map).cast<String, dynamic>();
    final splits = (metadata['splits'] as Map).map((key, value) {
      final split = value as Map;
      return MapEntry(
        key as String,
        MobiSplit(
          (split['paths'] as List).cast<String>(),
          (split['anchors'] as Map).cast<String, String>(),
        ),
      );
    });
    final originals = <String, String>{};
    for (final entry in _segments.entries) {
      originals[entry.key] = (entry.value as List)[0] as String;
    }
    rewriter = MobiRewriter(native.version >= 8, splits, originals);
    sizes = {
      for (final entry in _nativeEntries.values)
        if (!splits.containsKey(entry.name)) entry.name: entry.size,
    };
    for (final entry in _segments.entries) {
      final value = entry.value as List;
      final source = _nativeEntries[value[0]];
      if (source == null ||
          normalizeEntryPath(entry.key) != entry.key ||
          sizes.containsKey(entry.key)) {
        throw const FormatException('MOBI分段来源无效');
      }
      var size = 0;
      for (final part in value[1] as List) {
        if (part is String) {
          size += utf8.encode(part).length;
        } else {
          final span = part as List;
          final start = span[0] as int, length = span[1] as int;
          if (span.length != 2 ||
              start < 0 ||
              length < 0 ||
              start > source.size ||
              length > source.size - start) {
            throw const FormatException('MOBI分段范围无效');
          }
          size += length;
        }
      }
      if (size > EpubArchive.maxEntryBytes) {
        throw const FormatException('MOBI分段过大');
      }
      sizes[entry.key] = size;
    }
    sizes['content.opf'] = utf8.encode(metadata['opf'] as String).length;
    sizes['META-INF/container.xml'] = utf8.encode(_container).length;
    sizes['mimetype'] = 20;
    if (sizes.length > EpubArchive.maxEntries ||
        sizes.values.fold<int>(0, (sum, size) => sum + size) >
            EpubArchive.maxTotalBytes) {
      throw const FormatException('MOBI正文和资源超出上限');
    }
    for (final split in splits.entries) {
      if (!_nativeEntries.containsKey(split.key) ||
          split.value.paths.isEmpty ||
          split.value.paths.any((path) => !_segments.containsKey(path)) ||
          split.value.anchors.values.any(
            (path) => !split.value.paths.contains(path),
          )) {
        throw const FormatException('MOBI目录与分段不一致');
      }
    }
  }

  final DirectMobi native;
  final Map<String, dynamic> metadata;
  late final Map<String, MobiEntry> _nativeEntries;
  late final Map<String, dynamic> _segments;
  late final MobiRewriter rewriter;
  @override
  late final Map<String, int> sizes;

  static Future<MobiPublicationSource> build(
    String source, {
    required bool Function() isCancelled,
    void Function(double)? onProgress,
    void Function(String)? onStage,
  }) async {
    final native = DirectMobi(source, sequentialRead: true);
    try {
      await native.buildIndex(
        isCancelled: isCancelled,
        onProgress: (value) => onProgress?.call(.55 * value),
      );
      onStage?.call('native_index');
      final entries = {for (final entry in native.entries) entry.name: entry};
      final opf = XmlDocument.parse(
        utf8.decode(native.readEntry(entries['content.opf']!)),
      );
      final splits = <String, MobiSplit>{};
      final segments = <String, Object>{};
      final splitIds = <String, List<String>>{};
      final items = opf.findAllElements('item').toList();
      for (var at = 0; at < items.length; at++) {
        final item = items[at];
        final href = item.getAttribute('href')!;
        final entry = entries[href];
        if (entry == null) throw const FormatException('MOBI清单内容缺失');
        if ((item.getAttribute('media-type') ?? '').contains('html') &&
            entry.size >= 256 * 1024) {
          final recipes = MobiSplitRecipes();
          final split = await indexMobiHtml(
            href,
            Stream<List<int>>.fromIterable(native.entryChunks(entry)),
            recipes,
          );
          if (split != null) {
            splits[href] = split;
            segments.addAll({
              for (final part in recipes.segments.entries)
                part.key: [href, part.value],
            });
            final id = item.getAttribute('id')!;
            final replacements = <XmlElement>[];
            final ids = <String>[];
            for (var i = 0; i < split.paths.length; i++) {
              final copy = item.copy();
              final newId = '$id-s$i';
              copy.setAttribute('id', newId);
              copy.setAttribute('href', split.paths[i]);
              ids.add(newId);
              replacements.add(copy);
            }
            splitIds[id] = ids;
            final parent = item.parent!, index = parent.children.indexOf(item);
            parent.children.removeAt(index);
            parent.children.insertAll(index, replacements);
          }
        }
        onProgress?.call(.55 + .45 * (at + 1) / items.length);
        await Future<void>.delayed(Duration.zero);
        if (isCancelled()) throw const MobiReadFailure(7);
      }
      for (final ref in opf.findAllElements('itemref').toList()) {
        final ids = splitIds[ref.getAttribute('idref')];
        if (ids == null) continue;
        final parent = ref.parent!, index = parent.children.indexOf(ref);
        parent.children.removeAt(index);
        parent.children.insertAll(index, [
          for (final id in ids) ref.copy()..setAttribute('idref', id),
        ]);
      }
      onStage?.call('segment_index');
      return MobiPublicationSource._(native, {
        'version': 1,
        'segments': segments,
        'splits': {
          for (final entry in splits.entries)
            entry.key: {
              'paths': entry.value.paths,
              'anchors': entry.value.anchors,
            },
        },
        'opf': opf.toXmlString(),
      });
    } catch (_) {
      native.close();
      rethrow;
    }
  }

  /// Identity is verified against the manifest before parsing book-controlled
  /// ranges. Restore additionally rebuilds and compares recipes from source.
  static MobiPublicationSource open(
    String source,
    File index, {
    required String digest,
    required int bytes,
  }) {
    if (bytes < 12 ||
        bytes > EpubArchive.maxEntryBytes ||
        index.lengthSync() != bytes) {
      throw const FormatException('MOBI读取索引大小不符');
    }
    final data = index.readAsBytesSync();
    final hash = NativeSha256();
    late final String actualDigest;
    try {
      hash.add(data);
      actualDigest = hash.finish();
    } finally {
      hash.close();
    }
    if (actualDigest != digest ||
        ascii.decode(data.sublist(0, 8)) != 'GTMOBD02') {
      throw const FormatException('MOBI读取索引损坏');
    }
    final length = ByteData.sublistView(data).getUint32(8, Endian.little);
    if (length > data.length - 12) throw const FormatException('MOBI读取索引截断');
    final native = DirectMobi(source);
    try {
      native.importIndex(Uint8List.sublistView(data, 12, 12 + length));
      final metadata = jsonDecode(
        utf8.decode(Uint8List.sublistView(data, 12 + length)),
      ) as Map<String, dynamic>;
      if (metadata['version'] != 1) throw const FormatException('不支持的MOBI读取索引');
      return MobiPublicationSource._(native, metadata);
    } catch (_) {
      native.close();
      rethrow;
    }
  }

  Uint8List exportIndex() {
    final nativeBytes = native.exportIndex();
    final json = utf8.encode(jsonEncode(metadata));
    final size = 12 + nativeBytes.length + json.length;
    if (size > EpubArchive.maxEntryBytes) {
      throw const FormatException('MOBI读取索引过大');
    }
    final out = Uint8List(size);
    out.setAll(0, ascii.encode('GTMOBD02'));
    ByteData.sublistView(out).setUint32(8, nativeBytes.length, Endian.little);
    out.setAll(12, nativeBytes);
    out.setAll(12 + nativeBytes.length, json);
    return out;
  }

  @override
  Uint8List readBytes(String path) {
    final bytes = _readSourceBytes(path);
    if ({
      '.html',
      '.xhtml',
      '.ncx',
      '.opf',
      '.css',
    }.contains(p.extension(path).toLowerCase())) {
      return Uint8List.fromList(
        utf8.encode(rewriter.rewrite(utf8.decode(bytes), path)),
      );
    }
    return bytes;
  }

  @override
  List<Uint8List> readBytesBatch(List<String> paths) {
    final result = [for (final path in paths) _readSourceBytes(path)];
    final text = [
      for (var i = 0; i < paths.length; i++)
        if ({
          '.html',
          '.xhtml',
          '.ncx',
          '.opf',
          '.css',
        }.contains(p.extension(paths[i]).toLowerCase()))
          i,
    ];
    // 图片／字体等原始字节不经过文本解码，保留BOM与所有二进制内容。
    final rewritten = rewriter.rewriteBatch(
      [for (final i in text) utf8.decode(result[i])],
      [for (final i in text) paths[i]],
    );
    for (var i = 0; i < text.length; i++) {
      result[text[i]] = rewritten[i];
    }
    return result;
  }

  Uint8List _readSourceBytes(String path) {
    if (!sizes.containsKey(path)) throw FormatException('缺少MOBI条目：$path');
    if (path == 'mimetype') {
      return Uint8List.fromList(ascii.encode('application/epub+zip'));
    }
    if (path == 'META-INF/container.xml') {
      return Uint8List.fromList(utf8.encode(_container));
    }
    final Uint8List bytes;
    if (path == 'content.opf') {
      bytes = Uint8List.fromList(utf8.encode(metadata['opf'] as String));
    } else if (_segments.containsKey(path)) {
      final value = _segments[path] as List;
      final source = _nativeEntries[value[0]]!;
      final builder = BytesBuilder(copy: false);
      for (final part in value[1] as List) {
        if (part is String) {
          builder.add(utf8.encode(part));
        } else {
          final span = part as List;
          builder.add(
            native.readEntry(
              source,
              offset: span[0] as int,
              length: span[1] as int,
            ),
          );
        }
      }
      bytes = builder.takeBytes();
    } else {
      bytes = native.readEntry(_nativeEntries[path]!);
    }
    return bytes;
  }

  @override
  void close() => native.close();
}
