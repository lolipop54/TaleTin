import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app/bootstrap.dart';
import 'core/diagnostics/app_opening_diagnostics.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  installOpeningDiagnostics();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Long Cang',
    ], await rootBundle.loadString('assets/fonts/reading_quote/OFL.txt'));
    yield LicenseEntryWithLineBreaks([
      'American English hyphenation dictionary',
    ], await rootBundle.loadString('assets/hyphenation/README_hyph_en_US.txt'));
  });
  // 阅读体验以竖屏为主
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // 数据库初始化与导入残留回收在 StartupGate 内完成，准备好后再显示书架
  runApp(const StartupGate());
}
