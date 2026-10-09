/// EPUB 结构解析：container.xml、OPF 包文档、EPUB3 nav 与 EPUB2 NCX 目录。
///
/// 只取本项目需要的字段，不追求完整支持 EPUB 规范；固定版式、脚本交互
/// 类书籍由上层按解析结果给出兼容性提示。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../../core/errors/import_error.dart';
import 'epub_archive.dart';
import 'epub_dom.dart';

/// manifest 条目。
class EpubManifestItem {
  const EpubManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.entryPath,
    this.properties = '',
  });

  final String id;
  final String href;
  final String mediaType;

  /// 归档内规范化路径
  final String entryPath;

  /// EPUB3 properties（cover-image / nav / scripted ...）
  final String properties;

  bool get isNav => properties.split(' ').contains('nav');
  bool get isCoverImage => properties.split(' ').contains('cover-image');
  bool get isNcx => mediaType.contains('dtbncx') || href.endsWith('.ncx');
  bool get isXhtml =>
      mediaType.contains('xhtml') ||
      mediaType.contains('html') ||
      href.endsWith('.xhtml') ||
      href.endsWith('.html') ||
      href.endsWith('.htm');
}

/// OPF 包文档的解析结果。
class EpubPackage {
  const EpubPackage({
    required this.version,
    required this.opfPath,
    required this.title,
    required this.author,
    required this.manifest,
    required this.spine,
    this.uniqueIdentifier = '',
    this.navItem,
    this.ncxItem,
    this.coverItem,
    this.fixedLayout = false,
  });

  final String version;
  final String opfPath;
  final String title;
  final String author;

  /// 出版标识：`package@unique-identifier` 指向的 `dc:identifier`。
  ///
  /// 嵌入字体解混淆的 key 由它推导（EPUB 3.3 字体混淆），所以必须原样保留，
  /// 不能顺手 trim 掉内部空白以外的内容——key 算错字体就是一堆乱码。
  final String uniqueIdentifier;

  /// 按 id 索引的 manifest
  final Map<String, EpubManifestItem> manifest;

  /// 阅读顺序（已过滤 linear="no"）
  final List<EpubManifestItem> spine;
  final EpubManifestItem? navItem;
  final EpubManifestItem? ncxItem;
  final EpubManifestItem? coverItem;

  /// 固定版式书籍（`meta[name=fixed-layout]`，漫画类多见）。
  ///
  /// 这类书不做重排，只按「一页一个图片」顺排显示，因此导入时给一句说明。
  final bool fixedLayout;

  /// 解析 `META-INF/container.xml` 得到 OPF 路径。
  static String readOpfPath(EpubArchive archive) {
    const containerPath = 'META-INF/container.xml';
    final content = archive.readText(containerPath);
    final XmlDocument document;
    try {
      document = XmlDocument.parse(content);
    } on XmlException {
      throw const ImportFailure(
        ImportErrorCode.invalidContainer,
        'container.xml 解析失败',
      );
    }
    for (final element in document.descendantElements) {
      if (element.name.local == 'rootfile') {
        final fullPath = element.getAttribute('full-path');
        final normalized = fullPath == null
            ? null
            : normalizeEntryPath(fullPath);
        if (normalized != null) return normalized;
      }
    }
    throw const ImportFailure(ImportErrorCode.invalidContainer, '缺少 OPF 路径');
  }

  /// 解析 OPF 包文档。
  static EpubPackage parse(EpubArchive archive, String opfPath) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(archive.readText(opfPath));
    } on XmlException {
      throw const ImportFailure(ImportErrorCode.invalidContainer, 'OPF 解析失败');
    }
    final root = document.rootElement;

    final manifest = <String, EpubManifestItem>{};
    final spineOrder = <String>[];
    final spineLinear = <String, bool>{};
    String? tocId;
    String? metaCoverId;
    String? guideCoverHref;
    var fixedLayout = false;
    final uniqueIdentifier = _uniqueIdentifier(root);

    for (final element in root.descendantElements) {
      switch (element.name.local) {
        case 'item':
          final id = element.getAttribute('id');
          final href = element.getAttribute('href');
          if (id == null || href == null) break;
          final entryPath = resolveEntryPath(opfPath, href);
          if (entryPath == null) break;
          manifest[id] = EpubManifestItem(
            id: id,
            href: href,
            mediaType: element.getAttribute('media-type') ?? '',
            entryPath: entryPath,
            properties: element.getAttribute('properties') ?? '',
          );
        case 'itemref':
          final idref = element.getAttribute('idref');
          if (idref == null) break;
          spineOrder.add(idref);
          spineLinear[idref] = element.getAttribute('linear') != 'no';
        case 'spine':
          tocId = element.getAttribute('toc');
        case 'meta':
          if (element.getAttribute('name') == 'cover') {
            metaCoverId = element.getAttribute('content');
          }
          if (element.getAttribute('name') == 'fixed-layout' &&
              element.getAttribute('content') == 'true') {
            fixedLayout = true;
          }
        case 'reference':
          if (element.getAttribute('type') == 'cover' &&
              guideCoverHref == null) {
            guideCoverHref = element.getAttribute('href');
          }
      }
    }

    final spine = <EpubManifestItem>[];
    for (final idref in spineOrder) {
      if (spineLinear[idref] == false) continue;
      final item = manifest[idref];
      if (item != null && item.isXhtml) spine.add(item);
    }
    if (spine.isEmpty) {
      throw const ImportFailure(ImportErrorCode.invalidContainer, '缺少正文 spine');
    }

    return EpubPackage(
      version: root.getAttribute('version') ?? '2.0',
      opfPath: opfPath,
      title: _metadataText(root, 'title'),
      author: _metadataText(root, 'creator'),
      manifest: manifest,
      spine: spine,
      uniqueIdentifier: uniqueIdentifier,
      navItem: _firstWhere(manifest.values, (i) => i.isNav),
      ncxItem: _resolveNcx(manifest, tocId),
      coverItem: _resolveCover(manifest, metaCoverId, guideCoverHref, opfPath),
      fixedLayout: fixedLayout,
    );
  }

  /// 取出版标识：优先 `package@unique-identifier` 指向的那一个，
  /// 没声明时退回第一个 `dc:identifier`。
  static String _uniqueIdentifier(XmlElement root) {
    final wantedId = root.getAttribute('unique-identifier');
    var fallback = '';
    for (final element in root.descendantElements) {
      if (element.name.local != 'identifier') continue;
      final text = element.innerText.trim();
      if (text.isEmpty) continue;
      if (wantedId != null && element.getAttribute('id') == wantedId) {
        return text;
      }
      if (fallback.isEmpty) fallback = text;
    }
    return fallback;
  }

  static EpubManifestItem? _resolveNcx(
    Map<String, EpubManifestItem> manifest,
    String? tocId,
  ) {
    final byId = tocId == null ? null : manifest[tocId];
    if (byId != null) return byId;
    return _firstWhere(manifest.values, (i) => i.isNcx);
  }

  /// 封面识别：EPUB3 `cover-image` 属性 → EPUB2 `meta[name=cover]`
  /// → guide 的 `type="cover"` 引用（设计文档 6.3）。
  static EpubManifestItem? _resolveCover(
    Map<String, EpubManifestItem> manifest,
    String? metaCoverId,
    String? guideCoverHref,
    String opfPath,
  ) {
    final byProperties = _firstWhere(manifest.values, (i) => i.isCoverImage);
    if (byProperties != null) return byProperties;
    if (metaCoverId != null) {
      final item = manifest[metaCoverId];
      if (item != null) return item;
    }
    if (guideCoverHref != null) {
      final entryPath = resolveEntryPath(opfPath, guideCoverHref);
      if (entryPath != null) {
        for (final item in manifest.values) {
          if (item.entryPath == entryPath) return item;
        }
      }
    }
    // 兜底：文件名像封面且是图片
    return _firstWhere(
      manifest.values,
      (i) =>
          i.mediaType.startsWith('image/') &&
          i.href.toLowerCase().contains('cover'),
    );
  }

  /// 取 dc:title / dc:creator 的文本，多个时用「、」连接。
  static String _metadataText(XmlElement root, String localName) {
    final values = <String>[];
    for (final element in root.descendantElements) {
      if (element.name.local != localName) continue;
      final text = element.innerText.trim();
      if (text.isNotEmpty) values.add(text);
    }
    return values.join('、');
  }
}

/// 目录原始条目：只带标题与归档内引用，章节 ID 由解析器映射。
class RawTocEntry {
  const RawTocEntry({
    required this.title,
    this.href,
    this.fragment,
    this.children = const [],
  });

  final String title;

  /// 归档内规范化路径（不含片段）
  final String? href;
  final String? fragment;
  final List<RawTocEntry> children;

  bool get isLeaf => children.isEmpty;
}

/// 解析 EPUB3 nav 文档（XHTML）。
List<RawTocEntry> parseNavDocument(String source, String navPath) {
  final document = html_parser.parse(source);
  final navs = document.querySelectorAll('nav');
  if (navs.isEmpty) return const [];
  // 优先取 epub:type="toc" 的 nav，没有标注时用第一个
  // （epub:type 是带命名空间的属性，要用 domAttribute 取，见 epub_dom.dart）
  Element toc = navs.first;
  for (final nav in navs) {
    final type =
        domAttribute(nav, 'epub:type') ?? domAttribute(nav, 'type') ?? '';
    if (type.split(' ').contains('toc')) {
      toc = nav;
      break;
    }
  }
  final list = toc.querySelector('ol');
  if (list == null) return const [];
  return _parseNavList(list, navPath);
}

List<RawTocEntry> _parseNavList(Element list, String navPath) {
  final entries = <RawTocEntry>[];
  for (final item in list.children.where((e) => e.localName == 'li')) {
    final anchor = item.children.firstWhere(
      (e) => e.localName == 'a' || e.localName == 'span',
      orElse: () => item,
    );
    final title = _cleanTitle(anchor.text);
    final href = anchor.localName == 'a' ? anchor.attributes['href'] : null;
    final childList = item.children.firstWhere(
      (e) => e.localName == 'ol',
      orElse: () => item,
    );
    final children = identical(childList, item)
        ? const <RawTocEntry>[]
        : _parseNavList(childList, navPath);
    if (title.isEmpty && children.isEmpty) continue;
    entries.add(
      RawTocEntry(
        title: title,
        href: href == null ? null : resolveEntryPath(navPath, href),
        fragment: href == null ? null : Uri.tryParse(href)?.fragment,
        children: children,
      ),
    );
  }
  return entries;
}

/// 解析 EPUB2 NCX 目录。
List<RawTocEntry> parseNcxDocument(String source, String ncxPath) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(source);
  } on XmlException {
    return const [];
  }
  for (final element in document.descendantElements) {
    if (element.name.local == 'navMap') {
      return _parseNavPoints(element, ncxPath);
    }
  }
  return const [];
}

List<RawTocEntry> _parseNavPoints(XmlElement parent, String ncxPath) {
  final entries = <RawTocEntry>[];
  for (final point in parent.childElements) {
    if (point.name.local != 'navPoint') continue;
    final entry = _parseNavPoint(point, ncxPath);
    if (entry != null) entries.add(entry);
  }
  return entries;
}

/// 解析一个 navPoint。旧实现把子 navPoint 当成容器再向下一层遍历，
/// 会跳过当前这一层，像「一本书 → 100 章」这样的 NCX 最后只剩书名。
RawTocEntry? _parseNavPoint(XmlElement point, String ncxPath) {
  var title = '';
  String? href;
  String? fragment;
  final children = <RawTocEntry>[];
  for (final child in point.childElements) {
    switch (child.name.local) {
      case 'navLabel':
        for (final text in child.childElements) {
          if (text.name.local == 'text') title = _cleanTitle(text.innerText);
        }
      case 'content':
        final src = child.getAttribute('src');
        if (src != null) {
          href = resolveEntryPath(ncxPath, src);
          fragment = Uri.tryParse(src)?.fragment;
        }
      case 'navPoint':
        final nested = _parseNavPoint(child, ncxPath);
        if (nested != null) children.add(nested);
    }
  }
  if (title.isEmpty && children.isEmpty) return null;
  return RawTocEntry(
    title: title,
    href: href,
    fragment: fragment,
    children: children,
  );
}

/// 目录标题清洗：折叠空白并限制长度。
String _cleanTitle(String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= 120) return text;
  return text.substring(0, 120);
}

T? _firstWhere<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

/// 判断 OPF 所在目录，供上层拼接相对路径使用。
String opfDirectory(String opfPath) {
  final dir = p.posix.dirname(opfPath);
  return dir == '.' ? '' : dir;
}
