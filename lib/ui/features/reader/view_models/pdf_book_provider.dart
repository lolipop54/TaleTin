import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../app/di/app_providers.dart';
import '../../../../data/services/pdf_book_controller.dart';
import 'reader_session_view_model.dart';
import 'reader_settings_view_model.dart';
import '../../../../domain/models/book.dart';

final pdfBookProvider = FutureProvider.autoDispose
    .family<PdfBookController, String>((ref, id) async {
      final book = ref.watch(
        readerSessionProvider(id).select((s) => s.value?.book),
      );
      if (book == null) throw StateError('PDF书籍尚未准备好');
      final chapters = await ref.read(bookRepositoryProvider).chaptersOf(id);
      var disposed = false;
      PdfBookController? opened;
      ref.onDispose(() {
        disposed = true;
        if (opened != null) unawaited(opened.close());
      });
      final result = await PdfBookController.open(
        book,
        chapters,
        ref.read(chapterContentRepositoryProvider),
        p.join(ref.read(libraryRootPathProvider), id),
      );
      if (disposed) {
        await result.close();
        throw StateError('PDF阅读已取消');
      }
      return opened = result;
    });

final pdfModeProvider = Provider.autoDispose.family<bool, String>(
  (ref, id) =>
      ref.watch(
            readerSessionProvider(id).select((s) => s.value?.book.format),
          ) ==
          BookFormat.pdf &&
      ref.watch(
            readerSettingsProvider(id)
                .select((s) => s.value?.settings.layoutMode.isOriginal),
          ) ==
          true,
);
