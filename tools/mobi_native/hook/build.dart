// Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final android = input.config.code.targetOS == OS.android;
    await CBuilder.library(
      name: 'taletin_mobi',
      assetName: 'mobi_native',
      sources: [
        'src/extract.c',
        'src/direct.c',
        'src/book_read.c',
        'src/book_structure.c',
        'src/book_links.c',
        'src/book_index.c',
        'src/miniz_impl.c',
        for (final name in [
          'buffer',
          'compression',
          'debug',
          'index',
          'memory',
          'meta',
          'parse_rawml',
          'read',
          'structure',
          'util',
          'write',
          'opf',
          'xmlwriter',
        ])
          'third_party/libmobi/src/$name.c',
      ],
      includes: ['src', 'third_party/libmobi/src'],
      defines: {
        'USE_XMLWRITER': null,
        'USE_MINIZ': null,
        if (android) 'HAVE_UNISTD_H': null,
        if (android) 'HAVE_STRDUP': null,
        if (android) 'HAVE_ATTRIBUTE_NORETURN': null,
        'MOBI_INLINE': android ? 'inline' : '__inline',
        'PACKAGE_VERSION': '"0.12"',
      },
      flags: android ? ['-Wl,-z,max-page-size=16384'] : [],
      ndebugDefine: false,
      std: android ? 'c99' : 'c11',
    ).run(input: input, output: output);
  });
}
