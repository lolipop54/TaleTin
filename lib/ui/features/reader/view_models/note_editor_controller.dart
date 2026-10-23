/// 笔记编辑器的状态与规则（实现计划 N4）。
///
/// 这里管的是「想法」这一层，不碰界面：
/// - 输入停顿一小会儿就把草稿写进本地，切后台或被系统杀掉都不丢；
/// - 只有**保存成功**才算一条笔记，同时清掉草稿；
/// - 保存失败保留输入并给出提示，编辑框不关；
/// - 明确放弃（或返回时选择放弃）才清草稿；
/// - 编辑已有标注时改的是同一条记录（带 id 保存），不会多出一条。
///
/// 草稿与已保存笔记是两回事：草稿不进笔记列表，也不算成就数量。
library;

import 'package:taletin/core/diagnostics/app_errors.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/locator.dart';
import '../../../../domain/models/note_draft.dart';
import '../../../../domain/repositories/annotation_repository.dart';
import '../../../../domain/repositories/note_draft_repository.dart';

/// 输入停顿多久写一次草稿：够短，切后台也不容易丢；够长，不会每个字写一次库。
const Duration kNoteDraftDelay = Duration(milliseconds: 600);

class NoteEditorController extends ChangeNotifier {
  NoteEditorController({
    required this.bookId,
    required this.range,
    required this.quote,
    required this.chapterTitle,
    required this.annotations,
    required this.drafts,
    Annotation? existing,
    AnnotationColor? color,
    this.draftDelay = kNoteDraftDelay,
  })  : _existingId = existing?.id,
        _body = existing?.body ?? '',
        _initialBody = existing?.body ?? '',
        _color = color ?? existing?.color ?? AnnotationColor.yellow;

  final String bookId;

  /// 已规范化的选区（N3 的产物）
  SelectionRange range;

  /// 更新中仍保留输入，但旧选区之后保存时必须重新核对，不能直接画到新正文。
  void sourceChanged() {
    range = SelectionRange(start: range.start.copyWith(needsRelocation: true),
      end: range.end.copyWith(needsRelocation: true));
  }

  /// 选文完整摘录
  final String quote;
  final String chapterTitle;

  /// 标注与草稿仓库；由调用方（阅读页）注入
  final AnnotationRepository annotations;
  final NoteDraftRepository drafts;

  /// 输入停顿多久写一次草稿
  final Duration draftDelay;

  Timer? _timer;
  String _body;
  String _initialBody;
  final String? _existingId;
  AnnotationColor? _color;
  String? _savedId;
  bool _isSaving = false;
  String? _error;
  bool _disposed = false;

  String get body => _body;

  /// 保存中：按钮转圈并挡住连点
  bool get isSaving => _isSaving;

  /// 上一次保存失败的原因（界面提示用，重试后清空）
  String? get error => _error;

  /// 记录 id：新写的第一次保存后就有值，之后是「改这一条」
  String? get savedId => _savedId;

  /// 正在改已有的标注（而不是新写一条）
  bool get isEditingExisting => _existingId != null;

  /// 这条标注的颜色；高亮必须有底色，笔记可以不带（列表里算「文字笔记」）
  AnnotationColor? get color => _color;

  /// 改颜色；空表示不要底色（保存时会按类型校正）
  void setColor(AnnotationColor? value) {
    if (value == _color) return;
    _color = value;
    notifyListeners();
  }

  /// 有没保存过的改动：返回时要问一句「放弃修改」
  bool get hasUnsavedChanges => _body.trim() != _initialBody.trim();

  /// 空想法本身没有可保存的内容；但改已有笔记时把文字删空是一种改动，
  /// 保存按钮要能用——点它会问「保留高亮还是删掉整条」。
  bool get canSave =>
      !_isSaving &&
      (_body.trim().isNotEmpty || (isEditingExisting && hasUnsavedChanges));

  /// 打开编辑器：有这本书的草稿且写的是同一段选文时，把想法接着填回来
  Future<void> load() async {
    final draft = await drafts.load(bookId);
    if (_disposed) return;
    if (draft == null || draft.quote != quote || !_isSameStart(draft.range)) return;
    _body = draft.body;
    _initialBody = draft.body;
    notifyListeners();
  }

  /// 输入变化：先更新界面，再安排一次草稿写入
  void updateBody(String value) {
    if (value == _body) return;
    _body = value;
    _error = null;
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(draftDelay, () => unawaited(flushDraft()));
  }

  /// 立刻写草稿（关闭面板、切后台时调用，不等待延时）
  Future<void> flushDraft() async {
    _timer?.cancel();
    _timer = null;
    final text = _body.trim();
    // 删空了就不留草稿；否则记下当前内容与这段选文
    if (text.isEmpty) {
      await drafts.clear(bookId);
      return;
    }
    await drafts.save(
      bookId,
      NoteDraft(
        range: range,
        quote: quote,
        body: _body,
        chapterTitle: chapterTitle,
        savedAt: DateTime.now(),
      ),
    );
  }

  /// 保存成一条笔记：成功返回 true（调用方据此关闭编辑框）。
  ///
  /// 连点保存只做一次；失败时保留输入与草稿，由用户重试。
  Future<bool> save() async {
    if (_isSaving) return false;
    final text = _body.trim();
    if (text.isEmpty) return false;
    _isSaving = true;
    _error = null;
    notifyListeners();
    try {
      _savedId = await annotations.saveAnnotation(
        id: _savedId ?? _existingId,
        bookId: bookId,
        kind: AnnotationKind.note,
        range: range,
        quote: quote,
        body: text,
        color: _color,
        chapterTitle: chapterTitle,
      );
      _initialBody = _body;
      await drafts.clear(bookId);
      return true;
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '保存笔记失败');
      // 保存失败：输入和草稿都留着，用户可以直接重试
      _error = '保存失败，请重试';
      await flushDraft();
      return false;
    } finally {
      _isSaving = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 清空想法只留高亮：把这条标注改回 highlight（底色保留）
  Future<bool> saveAsHighlight() async {
    if (_isSaving) return false;
    _isSaving = true;
    _error = null;
    notifyListeners();
    try {
      _savedId = await annotations.saveAnnotation(
        id: _savedId ?? _existingId,
        bookId: bookId,
        kind: AnnotationKind.highlight,
        range: range,
        quote: quote,
        color: _color,
        chapterTitle: chapterTitle,
      );
      _body = '';
      _initialBody = '';
      await drafts.clear(bookId);
      return true;
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '保存高亮失败');
      _error = '保存失败，请重试';
      return false;
    } finally {
      _isSaving = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 删掉这条标注与草稿（用户在编辑器里选「删除这条」）
  Future<bool> remove() async {
    final id = _savedId ?? _existingId;
    if (id == null) return false;
    _isSaving = true;
    _error = null;
    notifyListeners();
    try {
      await annotations.deleteAnnotation(id);
      await drafts.clear(bookId);
      return true;
    } catch (error, appStack) {
      AppErrors.report(error, appStack, operation: '删除笔记失败');
      _error = '删除失败，请重试';
      return false;
    } finally {
      _isSaving = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 明确放弃这次编辑：清掉草稿
  Future<void> discard() async {
    _timer?.cancel();
    _timer = null;
    await drafts.clear(bookId);
  }

  /// 草稿写的是不是同一段选文（同一章、同一块、同一偏移）
  bool _isSameStart(SelectionRange other) =>
      !other.start.needsRelocation &&
      !other.end.needsRelocation &&
      !range.start.needsRelocation &&
      !range.end.needsRelocation &&
      other.start.chapterId == range.start.chapterId &&
      other.start.blockId == range.start.blockId &&
      other.start.utf16Offset == range.start.utf16Offset;

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
