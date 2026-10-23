import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/source_content_index.dart';
import '../../engine/parsers/epub/epub_archive.dart';
import '../../engine/parsers/mobi/mobi_source.dart';

EpubArchive openIndexedPublication(
  String source,
  String contentDirectory,
  SourceContentIndex index,
) {
  if (index.format == 'epub') return EpubArchive.open(source);
  if (!index.directMobi) {
    return EpubArchive.directory(
      p.join(contentDirectory, 'publication'),
      digests: index.publication,
    );
  }
  return EpubArchive.entries(
    MobiPublicationSource.open(
      source,
      File(p.join(contentDirectory, 'mobi.index')),
      digest: index.mobiIndex['sha256'] as String,
      bytes: index.mobiIndex['bytes'] as int,
    ),
  );
}
