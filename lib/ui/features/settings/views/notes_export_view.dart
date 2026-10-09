import 'package:taletin/ui/core/widgets/gt_app_bar.dart';
import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import '../../../../data/services/notes_export.dart';
import '../../../../domain/models/book.dart';
import '../../../../domain/models/annotation_query.dart';
import '../../achievements/view_models/notes_providers.dart';
import '../view_models/notes_export_view_model.dart';
import '../../../core/theme/gt_tokens.dart';

class NotesExportView extends ConsumerStatefulWidget {
  const NotesExportView({super.key});
  @override
  ConsumerState<NotesExportView> createState() => _NotesExportViewState();
}

class _NotesExportViewState extends ConsumerState<NotesExportView> {
  String _book = '';
  NoteExportFormat _format = NoteExportFormat.markdown;
  @override
  Widget build(BuildContext context) {
    final books = ref.watch(annotatedBooksProvider);
    final state = ref.watch(notesExportProvider);
    final vm = ref.read(notesExportProvider.notifier);
    return PopScope(
      canPop: !state.busy,
      child: Scaffold(
        appBar: GtAppBar(title: const Text('导出阅读笔记')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(GtSpacing.s5),
            child: books.value == null
                ? Center(
                    child: Text(
                      books.hasError ? '笔记书籍读取失败：${books.error}' : '正在读取笔记书籍…',
                    ),
                  )
                : ListView(
                    children: [
                      FSelect<String>.rich(
                        label: const Text('导出范围'),
                        enabled: !state.busy,
                        control: FSelectControl.lifted(
                          value: _book,
                          onChange: (value) => setState(() => _book = value!),
                        ),
                        format: (id) => id.isEmpty ? '全部书籍' :
                            _bookLabel(books.value!.firstWhere((b) => b.id == id)),
                        children: [
                          const FSelectItem(title: Text('全部书籍'), value: ''),
                          for (final book in books.value!)
                            FSelectItem(
                              value: book.id,
                              title: Text(
                                _bookLabel(book),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: GtSpacing.s5),
                      FSelect<NoteExportFormat>(
                        label: const Text('文件格式'),
                        enabled: !state.busy,
                        control: FSelectControl.lifted(
                          value: _format,
                          onChange: (value) => setState(() => _format = value!),
                        ),
                        items: const {
                          'Markdown · 方便阅读': NoteExportFormat.markdown,
                          'JSON · 保留结构化数据': NoteExportFormat.json,
                        },
                      ),
                      const SizedBox(height: GtSpacing.s2),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: GtSpacing.s4,
                        ),
                        child: Text(state.message),
                      ),
                      const SizedBox(height: GtSpacing.s2),
                      GtButton.filled(
                        onPressed: state.busy
                            ? null
                            : () => vm.export(
                                _format,
                                _book.isEmpty ? null : _book,
                              ),
                        child: const Text('选择位置并导出'),
                      ),
                      if (state.busy)
                        GtButton(
                          onPressed: vm.cancel,
                          child: const Text('取消操作'),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  String _bookLabel(AnnotatedBook book) =>
      '${book.title}${book.status == BookStatus.removed ? '（原书已移除）' : ''}';
}
