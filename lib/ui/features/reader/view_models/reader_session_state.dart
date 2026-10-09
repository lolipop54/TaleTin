import '../../../../domain/models/book.dart';
import '../../../../domain/models/book_document.dart';
import '../../../../domain/models/locator.dart';
import '../../../../domain/services/book_progress.dart' as progress;
import '../../../../engine/layout/chapter_layout.dart';
import '../../../../engine/normalization/text_anchor.dart';

/// 阅读会话失败：书没了、正文缺失、没有章节。
class ReaderFailure implements Exception {
  const ReaderFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 阅读会话状态。
class ReaderSession {
  const ReaderSession({
    required this.book,
    required this.chapters,
    required this.chapterIndex,
    this.content,
    this.layout,
    this.pageIndex = 0,
    this.viewportSignature,
    this.originalAnchor,
    this.originalFraction = 0,
    this.originalJump,
    this.scrolling = false,
    this.scrollAnchor,
    this.scrollJump,
  });

  final Book book;

  /// 全书章节索引（按 ordinal）；正文按需读取
  final List<Chapter> chapters;
  final int chapterIndex;

  final bool scrolling;
  final Locator? scrollAnchor;
  final ({int token, Locator locator})? scrollJump;

  /// 当前章正文与排版（首次排版完成后才有值）
  final ChapterContent? content;
  final ChapterLayout? layout;
  final int pageIndex;

  /// 本次排版使用的参数签名；与新的参数不一致时需要重排
  final String? viewportSignature;

  /// 原书排版模式下由 WebView 上报换算出的位置。
  ///
  /// 非空表示「现在读的是原书排版」，位置以它为准（[currentAnchor]、进度、
  /// 书签都走它）；切回简化模式时清掉，位置重新由排版结果给出。
  final Locator? originalAnchor;

  /// 原书模式下的章内比例 0–1（上报值，用于切回简化模式前的换算与兜底）
  final double originalFraction;

  /// 原书模式下的一次「章内定位」请求（进度滑块、书签回到原文、目录定位）。
  ///
  /// 原书模式没有简化排版可排，位置只能靠「切章 + 章内比例」表达；同一章内跳转
  /// 由正文区把这个请求下发给宿主页。[token] 递增，同一个位置连跳两次也能生效。
  final ({int token, double fraction, String? anchorId, String? title})?
  originalJump;

  bool get isReady => scrolling ? scrollAnchor != null
      : layout != null && layout!.pageCount > 0;

  /// 是否正在用原书排版（位置来自 WebView 上报）
  bool get isOriginal => originalAnchor != null;

  Chapter get chapter => chapters[chapterIndex];

  int get pageCount => layout?.pageCount ?? 0;

  /// 当前页的页首位置（重排后用它找回原句；书签与进度也用它）
  Locator? get currentAnchor {
    if (scrolling) return scrollAnchor;
    // 原书模式下排版结果可能是上一章的（甚至还没有），位置以上报值为准
    if (originalAnchor != null) return originalAnchor;
    final current = layout;
    if (current == null || !isReady) return null;
    return current.beginLocatorOf(current.page(pageIndex));
  }

  /// 当前页首的摘录（加书签时一起存，列表里展示）
  ///
  /// 原书模式没有排版结果，用上报位置换算出的 `Locator` 自带的摘录
  /// （它是从标准化正文里截出来的，与简化模式的摘录同源）。
  String get currentPageExcerpt {
    if (scrolling) return scrollAnchor?.exact ?? '';
    final original = originalAnchor;
    if (original != null) return original.exact;
    final current = layout;
    if (current == null || !isReady) return '';
    final text = current.textOfPage(pageIndex).trim();
    return text.length <= 40 ? text : '${text.substring(0, 40)}…';
  }

  /// 章内进度 0–1（按内容位置，与排版无关）
  double get chapterProgress =>
      scrolling ? _scrollFraction : isOriginal ? originalFraction
          : (layout?.progressOfPage(pageIndex) ?? 0);

  double get _scrollFraction => content == null || scrollAnchor == null ? 0
      : fractionOfLocator(content: content!, bookId: book.id,
          contentVersion: book.contentVersion, chapterId: chapter.id,
          locator: scrollAnchor!);

  /// 全书进度 0–1：已完成章节的字数 + 本章已读位置（与排版无关）
  double get bookProgress {
    if (scrolling) return bookProgressAt(chapterIndex, _scrollFraction);
    if (isOriginal) {
      return bookProgressAt(chapterIndex, originalFraction);
    }
    final current = layout;
    if (current == null) return 0;
    return bookProgressAt(chapterIndex, current.progressOfPage(pageIndex));
  }

  /// 按**内容文本长度**算的当前位置，与目录索引同一口径。
  ///
  /// 目录条目的进度是「章内字数 ÷ 本章字数」，字数里每块还带一个分隔符字符；
  /// 而原书模式上报的位置是版面比例（按页宽折算）。两者差 0.1% 到 0.4%
  /// （随块数增长），拿版面比例去比目录条目会差出一条：滑块下方的章名和
  /// 「下一章」会停在上一章、再点不动。这里用当前 `Locator` 反算文本比例，
  /// 与原书模式「按标题落点」后的上报位置正好对上（两边都是同一块的位置）。
  double get contentProgress {
    final locator = currentAnchor;
    final chapterContent = content;
    if (locator == null ||
        chapterContent == null ||
        chapterContent.chapterId != chapter.id) {
      return bookProgress;
    }
    return bookProgressAt(
      chapterIndex,
      fractionOfLocator(
        content: chapterContent,
        bookId: book.id,
        contentVersion: book.contentVersion,
        chapterId: chapter.id,
        locator: locator,
      ),
    );
  }

  /// [bookProgressAt] 的逆运算：全书进度 → 某一章的章内比例（原书模式的落点用它）。
  static double? chapterFractionOf(
    double progress,
    List<Chapter> chapters,
    Book book,
    int index,
  ) {
    if (index < 0 || index >= chapters.length) return null;
    final total = book.textLength;
    final chapter = chapters[index];
    if (total <= 0 || chapter.textLength <= 0) return null;
    var before = 0;
    for (var i = 0; i < index; i++) {
      before += chapters[i].textLength;
    }
    // 旧版本把章内已读字数四舍五入成整数后再保存。恢复时补回半个字符，
    // 避免原本恰好位于页边界的比例因舍入略小，WebView floor 后退到前一页。
    return ((progress * total - before + 0.5) / chapter.textLength).clamp(
      0.0,
      1.0,
    );
  }

  /// 按「章内比例」算全书进度：已完成章的字数 + 本章字数 × 比例。
  double bookProgressAt(int index, double fraction) {
    return progress.bookProgressAt(chapters, book.textLength, index, fraction);
  }

  ReaderSession copyWith({
    int? chapterIndex,
    ChapterContent? content,
    ChapterLayout? layout,
    int? pageIndex,
    String? viewportSignature,
    Locator? originalAnchor,
    double? originalFraction,
    ({int token, double fraction, String? anchorId, String? title})?
    originalJump,
    bool clearOriginalPosition = false,
    bool? scrolling,
    Locator? scrollAnchor,
    ({int token, Locator locator})? scrollJump,
  }) => ReaderSession(
    book: book,
    chapters: chapters,
    chapterIndex: chapterIndex ?? this.chapterIndex,
    scrolling: scrolling ?? this.scrolling,
    scrollAnchor: scrollAnchor ?? this.scrollAnchor,
    scrollJump: scrollJump ?? this.scrollJump,
    content: content ?? this.content,
    layout: layout ?? this.layout,
    pageIndex: pageIndex ?? this.pageIndex,
    viewportSignature: viewportSignature ?? this.viewportSignature,
    originalAnchor: clearOriginalPosition
        ? null
        : (originalAnchor ?? this.originalAnchor),
    originalFraction: clearOriginalPosition
        ? 0
        : (originalFraction ?? this.originalFraction),
    originalJump: originalJump ?? this.originalJump,
  );
}

/// 翻页结果：用于界面给出「已是第一页 / 最后一页」的反馈。
enum PageTurnResult { moved, atBookStart, atBookEnd }
