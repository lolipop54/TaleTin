import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/imported_font_store.dart';
import '../../platform/channels/imported_fonts.dart';

final importedFontStoreProvider = Provider<ImportedFontStore>(
  (ref) => ImportedFonts.store ?? (throw StateError('导入字体尚未初始化')),
);
