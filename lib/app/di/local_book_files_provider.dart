import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/local_book_files.dart';
import '../../platform/channels/android_local_book_files.dart';
import '../../data/services/local_import_matcher.dart';
import '../../data/services/local_file_scan_cache.dart';

final localFileScanCacheProvider =
    Provider.family<LocalFileScanCache, LocalFilePurpose>(
      (ref, purpose) => LocalFileScanCache(),
    );

final localImportMatcherProvider = Provider((ref) => LocalImportMatcher());

final localBookFilesProvider = Provider<LocalBookFiles>(
  (ref) => AndroidLocalBookFiles(),
);
