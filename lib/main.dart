import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app/bootstrap.dart';
import 'app/app_error_hooks.dart';
import 'core/diagnostics/app_opening_diagnostics.dart';
import 'engine/layout/math_typesetting.dart';
import 'data/services/flutter_tex_formula_renderer.dart';

void main() => runWithAppErrors(() {
  installOpeningDiagnostics();
  MathTypesetting.renderer = FlutterTexFormulaRenderer();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'MathJax / MathJax SVG fonts (Apache 2.0)',
    ], await rootBundle.loadString('assets/licenses/MathJax-Apache-2.0.txt'));
    yield LicenseEntryWithLineBreaks([
      'ReaderMath / Noto Sans CJK symbols (SIL Open Font License 1.1)',
    ], await rootBundle.loadString('assets/licenses/ReaderMath-OFL.txt'));
    yield LicenseEntryWithLineBreaks([
      'cssparser / selectors (Mozilla Public License 2.0)',
    ], await rootBundle.loadString('assets/licenses/CSSParser-MPL-2.0.txt'));
    yield LicenseEntryWithLineBreaks([
      'PDFium (chromium/7811) and bundled third-party components',
    ], await rootBundle.loadString('assets/licenses/PDFium-LICENSE.txt'));
    yield LicenseEntryWithLineBreaks(
      ['libmobi / TaleTin MOBI adapter (LGPL-3.0-or-later)'],
      await rootBundle.loadString(
        'tools/mobi_native/third_party/libmobi/COPYING',
      ),
    );
    yield LicenseEntryWithLineBreaks(
      ['GNU GPL v3 (incorporated by LGPL v3)'],
      await rootBundle.loadString(
        'tools/mobi_native/third_party/COPYING-GPL-3.0',
      ),
    );
    yield LicenseEntryWithLineBreaks(
      ['miniz (libmobi)'],
      await rootBundle.loadString(
        'tools/mobi_native/third_party/MINIZ-LICENSE',
      ),
    );
    yield LicenseEntryWithLineBreaks([
      'Long Cang',
    ], await rootBundle.loadString('assets/fonts/reading_quote/OFL.txt'));
    yield LicenseEntryWithLineBreaks([
      'American English hyphenation dictionary',
    ], await rootBundle.loadString('assets/hyphenation/README_hyph_en_US.txt'));
  });
  // StartupGate 读取保存的全局方向后，在书架首帧显示前应用。
  // 数据库初始化与导入残留回收在 StartupGate 内完成，准备好后再显示书架
  runApp(const StartupGate());
});
