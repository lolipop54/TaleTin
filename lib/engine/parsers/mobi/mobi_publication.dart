import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:html/parser.dart' as html;
import 'package:xml/xml.dart';

import '../../../core/errors/import_error.dart';
import '../../../core/diagnostics/import_timing.dart';
import '../epub/epub_archive.dart';
import 'mobi_splitter.dart';

/// KF7 往往只有一个巨大的 HTML。按块边界分段后改写目录和全部链接，
/// 两种排版使用同一份产物；分段只是读取单位，不丢正文也不虚构目录名称。
Future<void> prepareMobiPublication(
  Directory directory, {
  required bool kf8,
  void Function(double fraction)? onProgress,
}) async {
  final timing = traceImportPerf ? ImportTiming('mobi_publication') : null;
  final opf = File(p.join(directory.path, 'content.opf'));
  if (!opf.existsSync()) {
    throw const ImportFailure(ImportErrorCode.invalidContainer, '未能恢复出版物结构');
  }
  final package = XmlDocument.parse(await opf.readAsString());
  final splits = <String, MobiSplit>{};
  final originals = <String, String>{};
  final items = package.findAllElements('item').toList();
  final splitIds = <String, List<String>>{};
  final htmlSizes = <String, int>{
    for (final item in items)
      if ((item.getAttribute('media-type') ?? '').contains('html'))
        item.getAttribute('href')!: File(
          p.join(directory.path, item.getAttribute('href')!),
        ).lengthSync(),
  };
  final splitBytes = htmlSizes.values
      .where((size) => size >= 256 * 1024)
      .fold(0, (sum, size) => sum + size);
  var processedBytes = 0;
  timing?.mark('package_read');
  for (final item in items) {
    final href = item.getAttribute('href')!;
    if (!(item.getAttribute('media-type') ?? '').contains('html')) continue;
    final file = File(p.join(directory.path, href));
    final size = htmlSizes[href]!;
    if (size < 256 * 1024) continue;
    final split = await splitMobiHtml(
      file,
      onProgress: (bytes) =>
          onProgress?.call(.5 * (processedBytes + bytes) / splitBytes),
    );
    processedBytes += size;
    if (split == null) continue;
    splits[href] = split;
    final id = item.getAttribute('id')!;
    final ids = <String>[];
    final replacement = <XmlElement>[];
    for (var i = 0; i < split.paths.length; i++) {
      final copy = item.copy();
      final path = split.paths[i];
      originals[path] = href;
      final newId = '$id-s$i';
      ids.add(newId);
      copy.setAttribute('id', newId);
      copy.setAttribute('href', path);
      replacement.add(copy);
    }
    splitIds[id] = ids;
    final parent = item.parent!;
    final index = parent.children.indexOf(item);
    parent.children.removeAt(index);
    parent.children.insertAll(index, replacement);
  }
  timing?.mark('html_split');
  for (final ref in package.findAllElements('itemref').toList()) {
    final ids = splitIds[ref.getAttribute('idref')];
    if (ids == null) continue;
    final parent = ref.parent!;
    final index = parent.children.indexOf(ref);
    parent.children.removeAt(index);
    parent.children.insertAll(index, [
      for (final id in ids) ref.copy()..setAttribute('idref', id),
    ]);
  }
  await opf.writeAsString(package.toXmlString());
  timing?.mark('package_write');

  String rewriteLink(String raw, String name) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.hasScheme || uri.hasAuthority) return raw;
    final target = uri.path.isEmpty ? originals[name] ?? name : uri.path;
    final split = splits[target];
    if (split == null) return raw;
    return Uri(
      path: split.anchors[uri.fragment] ?? split.paths.first,
      fragment: uri.hasFragment ? uri.fragment : null,
    ).toString();
  }

  String media(String value) => value
      .replaceAll('amzn-kf8', kf8 ? 'screen' : 'taletin-kf8-disabled')
      .replaceAll('amzn-mobi', kf8 ? 'taletin-mobi-disabled' : 'screen');
  String stylesheet(String value) => value.replaceAllMapped(
    RegExp(r'(@media\s+)([^{}]+)(\{)', caseSensitive: false),
    (m) => '${m[1]}${media(m[2]!)}${m[3]}',
  );
  final files = directory.listSync().whereType<File>().where((file) {
    final name = p.basename(file.path);
    return !splits.containsKey(name) &&
        {
          '.html',
          '.xhtml',
          '.ncx',
          '.opf',
          '.css',
        }.contains(p.extension(name).toLowerCase());
  }).toList();
  onProgress?.call(.5);
  for (var index = 0; index < files.length; index++) {
    final file = files[index];
    final name = p.basename(file.path);
    final ext = p.extension(name).toLowerCase();
    var text = await file.readAsString();
    // 只改真实属性和媒体条件，不能把正文/代码示例里的 href 或 amzn-kf8 改掉。
    if (ext == '.css') {
      text = stylesheet(text);
    } else if (ext == '.html' || ext == '.xhtml') {
      final document = html.parse(text);
      for (final element in document.querySelectorAll(
        '[href], [src], [media], style',
      )) {
        for (final attribute in ['href', 'src']) {
          final value = element.attributes[attribute];
          if (value != null) {
            element.attributes[attribute] = rewriteLink(value, name);
          }
        }
        final condition = element.attributes['media'];
        if (condition != null) element.attributes['media'] = media(condition);
        if (element.localName == 'style') {
          element.text = stylesheet(element.text);
        }
      }
      text = document.outerHtml;
    } else {
      final document = XmlDocument.parse(text);
      for (final element in document.descendantElements) {
        for (final attribute in ['href', 'src']) {
          final value = element.getAttribute(attribute);
          if (value != null) {
            element.setAttribute(attribute, rewriteLink(value, name));
          }
        }
      }
      text = document.toXmlString();
    }
    await file.writeAsString(text);
    onProgress?.call(.5 + .5 * (index + 1) / files.length);
  }
  timing?.mark('links_media_rewrite');
  for (final old in splits.keys) {
    await File(p.join(directory.path, old)).delete();
  }
  var total = 0, count = 0;
  for (final file in directory.listSync().whereType<File>()) {
    final size = file.lengthSync();
    total += size;
    if (++count > EpubArchive.maxEntries ||
        size > EpubArchive.maxEntryBytes ||
        total > EpubArchive.maxTotalBytes) {
      throw const ImportFailure(ImportErrorCode.unsafeArchive, '重建内容超出大小或条目限制');
    }
  }
  timing?.mark('validate');
  timing?.report(counts: {'files': count, 'bytes': total});
}
