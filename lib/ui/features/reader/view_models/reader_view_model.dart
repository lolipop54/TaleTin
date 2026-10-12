import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/sample_data.dart';
import '../../../../domain/models/annotation.dart';
import '../../../../domain/models/locator.dart';

/// 一次笔记编辑请求：选区、摘录、章节标题与「改哪一条」
class NoteEditorRequest {
  const NoteEditorRequest({
    required this.range,
    required this.quote,
    required this.chapterTitle,
    this.existing,
  });

  /// 已规范化的选区（N3 的产物）
  final SelectionRange range;

  /// 选文完整摘录
  final String quote;
  final String chapterTitle;

  /// 这段选文上已有的标注：改它，而不是新建
  final Annotation? existing;

  @override
  bool operator ==(Object other) =>
      other is NoteEditorRequest &&
      other.range.start.samePosition(range.start) &&
      other.range.end.samePosition(range.end) &&
      other.quote == quote &&
      other.existing?.id == existing?.id;

  @override
  int get hashCode => Object.hash(
    range.start.chapterId,
    range.start.blockId,
    range.start.utf16Offset,
    range.end.utf16Offset,
    quote,
    existing?.id,
  );
}

/// 阅读器子面板
enum ReaderPanel { none, contents, brightness, typography, tts, auto, search }

/// 阅读器视图状态：沉浸/控制两层展示与五个子面板开关。
///
/// 排版参数（字号/行高/段距/页边距/缩进/字体/主题）不在这里：它们要落库并支持
/// 单书覆盖，由 `reader_settings_view_model.dart` 单独管（S10）。
class ReaderState {
  const ReaderState({
    this.chapterIndex = 0,
    this.progress = 0.37,
    this.controlsVisible = false,
    this.panel = ReaderPanel.none,
    this.panelCovered = false,
    this.followSystemBrightness = false,
    this.brightness = 0.68,
    this.bookmarked = false,
    this.contentsTab = 0, // 0=目录 1=书签 2=笔记
    this.expandedVolumes = const {0},
    this.selection,
    this.selectionFromMark = false,
    this.note,
    this.noteCloseToken = 0,
    this.notice,
    this.noticeToken = 0,
  });

  final int chapterIndex;

  /// 章内进度 0–1（演示数据）
  final double progress;

  /// 控制层（顶部栏+底部工具栏）是否显示
  final bool controlsVisible;
  final ReaderPanel panel;

  /// 子面板打开时保留父面板身份，但暂时收起父面板画面。
  final bool panelCovered;
  final bool followSystemBrightness;

  /// 应用窗口亮度 0–1（演示）
  final double brightness;
  final bool bookmarked;

  /// 综合面板当前页签
  final int contentsTab;

  /// 展开的分卷索引
  final Set<int> expandedVolumes;

  /// 选区（原型）：两个 Locator 界定的文本范围；null 表示没有选区
  final SelectionRange? selection;

  /// 这次选区是「点已有高亮/笔记」选出来的。
  ///
  /// 这种选区只用来摆操作菜单：不画起止手柄，也不铺临时底色（已有底色就是
  /// 高亮本身，再铺一层看起来像高亮被画了两遍、颜色更重）。要改范围就删掉
  /// 这条再重新选文字（用户口径）。
  final bool selectionFromMark;

  /// 正开着的笔记面板（写想法 / 编辑想法）；null 表示没开
  final NoteEditorRequest? note;

  /// 「请关闭笔记面板」的序号：返回键每次都加一，面板按序号走确认流程
  final int noteCloseToken;

  /// 正文区上的一次性提示（全书首尾、降级说明）；两种排版模式共用
  final String? notice;

  /// 提示的序号：同一句话连报两次也能重新弹一次
  final int noticeToken;

  DemoChapter get chapter => demoChapters[chapterIndex];
  String get bookTitle => demoReadingBook;

  ReaderState copyWith({
    int? chapterIndex,
    double? progress,
    bool? controlsVisible,
    ReaderPanel? panel,
    bool? panelCovered,
    bool? followSystemBrightness,
    double? brightness,
    bool? bookmarked,
    int? contentsTab,
    Set<int>? expandedVolumes,
    SelectionRange? selection,
    bool clearSelection = false,
    bool? selectionFromMark,
    NoteEditorRequest? note,
    bool clearNote = false,
    int? noteCloseToken,
    String? notice,
    int? noticeToken,
    bool clearNotice = false,
  }) {
    return ReaderState(
      chapterIndex: chapterIndex ?? this.chapterIndex,
      progress: progress ?? this.progress,
      controlsVisible: controlsVisible ?? this.controlsVisible,
      panel: panel ?? this.panel,
      panelCovered: panelCovered ?? this.panelCovered,
      followSystemBrightness:
          followSystemBrightness ?? this.followSystemBrightness,
      brightness: brightness ?? this.brightness,
      bookmarked: bookmarked ?? this.bookmarked,
      contentsTab: contentsTab ?? this.contentsTab,
      expandedVolumes: expandedVolumes ?? this.expandedVolumes,
      selection: clearSelection ? null : (selection ?? this.selection),
      selectionFromMark: clearSelection
          ? false
          : (selectionFromMark ?? this.selectionFromMark),
      note: clearNote ? null : (note ?? this.note),
      noteCloseToken: noteCloseToken ?? this.noteCloseToken,
      notice: clearNotice ? null : (notice ?? this.notice),
      noticeToken: noticeToken ?? this.noticeToken,
    );
  }
}

/// 阅读器 ViewModel：面板开关与设置调整都是纯展示逻辑。
class ReaderViewModel extends Notifier<ReaderState> {
  @override
  ReaderState build() => const ReaderState();

  void toggleControls() =>
      state = state.copyWith(controlsVisible: !state.controlsVisible);

  void openPanel(ReaderPanel panel, {int? contentsTab}) =>
      state = state.copyWith(
        panel: panel,
        controlsVisible: panel != ReaderPanel.search,
        panelCovered: false,
        contentsTab: contentsTab ?? state.contentsTab,
      );

  /// 目录可退回进度区，其余四个工具面板关闭后直接回正文。
  void closePanel({bool collapseControls = false}) {
    final hideControls =
        collapseControls ||
        switch (state.panel) {
          ReaderPanel.brightness ||
          ReaderPanel.tts ||
          ReaderPanel.auto ||
          ReaderPanel.typography => true,
          _ => false,
        };
    state = state.copyWith(
      panel: ReaderPanel.none,
      panelCovered: false,
      controlsVisible: hideControls ? false : state.controlsVisible,
    );
  }

  void coverPanel() => state = state.copyWith(panelCovered: true);
  void revealPanel() => state = state.copyWith(panelCovered: false);

  /// 切换演示章节（阶段 1 用于演示目录跳转与上一章/下一章）
  void setChapter(int index) => state = state.copyWith(
    chapterIndex: index.clamp(0, demoChapters.length - 1),
    progress: index == 1 ? 0.37 : 0.08,
  );

  void setProgress(double value) =>
      state = state.copyWith(progress: value.clamp(0.0, 1.0));

  void setFollowSystemBrightness(bool v) =>
      state = state.copyWith(followSystemBrightness: v);

  void setBrightness(double v) =>
      state = state.copyWith(brightness: v.clamp(0.0, 1.0));

  void nudgeBrightness(double delta) => setBrightness(state.brightness + delta);

  void toggleBookmark() =>
      state = state.copyWith(bookmarked: !state.bookmarked);

  void setContentsTab(int tab) => state = state.copyWith(contentsTab: tab);

  /// 长按起选：先选中所在的那一行（原型按行选，拖动再延伸）
  ///
  /// [fromMark] 为真表示这次选区是点已有高亮选出来的：只摆菜单，不画手柄与
  /// 临时底色（用户口径：已保存的高亮再点它不显示手柄）。
  void startSelection(Locator start, Locator end, {bool fromMark = false}) =>
      state = state.copyWith(
        selection: SelectionRange(start: start, end: end),
        selectionFromMark: fromMark,
      );

  /// 长按拖动：把选区另一端跟到这一点
  void extendSelection(Locator point) {
    final current = state.selection;
    if (current == null) return;
    state = state.copyWith(
      selection: SelectionRange(start: current.start, end: point),
      // 手动调整过范围就是新选区：手柄与临时底色要回来
      selectionFromMark: false,
    );
  }

  /// 拖起点手柄：只改选区开头，结尾不动（实现计划 S1b）
  void setSelectionStart(Locator point) {
    final current = state.selection;
    if (current == null) return;
    state = state.copyWith(
      selection: SelectionRange(start: point, end: current.end),
      selectionFromMark: false,
    );
  }

  /// 拖终点手柄：只改选区结尾，开头不动
  void setSelectionEnd(Locator point) {
    final current = state.selection;
    if (current == null) return;
    state = state.copyWith(
      selection: SelectionRange(start: current.start, end: point),
      selectionFromMark: false,
    );
  }

  void clearSelection() => state = state.copyWith(clearSelection: true);

  /// 打开笔记面板（贴在键盘上方）；选文不收起，方便对照着写
  void openNoteEditor(NoteEditorRequest request) =>
      state = state.copyWith(note: request);

  /// 关闭笔记面板；[clearSelection] 为真时连选区一起收起（保存、删除走它）
  void closeNoteEditor({bool clearSelection = false, String? notice}) =>
      state = state.copyWith(
        clearNote: true,
        clearSelection: clearSelection,
        notice: notice,
        noticeToken: notice == null ? state.noticeToken : state.noticeToken + 1,
      );

  /// 请求关闭笔记面板（返回键用）：面板自己走「有改动先问一句」的流程
  void requestCloseNoteEditor() =>
      state = state.copyWith(noteCloseToken: state.noteCloseToken + 1);

  /// 正文区弹一句提示（全书首尾、原书排版不可用等），显示一会儿自动消失
  void showNotice(String message) {
    // 听书换章可能在退出后才完成；旧页面的提示不能再写入已释放的界面状态。
    if (!ref.mounted) return;
    state = state.copyWith(notice: message, noticeToken: state.noticeToken + 1);
  }

  void clearNotice() => state = state.copyWith(clearNotice: true);

  void toggleVolume(int index) {
    final set = {...state.expandedVolumes};
    set.contains(index) ? set.remove(index) : set.add(index);
    state = state.copyWith(expandedVolumes: set);
  }
}

/// 控制层、面板和选区只属于本次阅读；退出页面后释放，下次从正文开始。
/// 阅读位置与单书设置由各自的 Provider 保存，不依赖这里的临时状态。
final readerProvider =
    NotifierProvider.autoDispose<ReaderViewModel, ReaderState>(
      ReaderViewModel.new,
    );

/// 阅读页显示时间（状态栏位）的来源。
/// 单独抽出是为了让测试能注入固定时间，避免 Golden 随当前时间抖动；
/// 阶段 5 会由 Clock 契约统一提供。
final readerClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);
