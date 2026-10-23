part of 'original_body.dart';

extension _OriginalInitialLayout on _OriginalBodyState {
  /// 设置和视口已确定，随iframe身份一同发布。子文档可先用最终样式布局，
  /// 但真实目录、标准正文、准确DOM点与高亮仍由原prepare/start流程提交。
  Map<String, Object?> _initialLayout(OriginalChapter chapter) => {
    'width': _width.round(),
    'margin': chapter.columnMarginPx.round(),
    'options': {
      'fontSizePx': ?chapter.fontSizePx,
      'lineHeight': ?chapter.lineHeight,
      'paragraphGapEm': ?chapter.paragraphGapEm,
      'marginPx': chapter.columnMarginPx,
      'indent': chapter.indent,
      'fontFamily': chapter.fontFamily,
      'fontWeight': chapter.fontWeight,
      'colors': ?chapter.themeColors,
    },
    'information': chapter.information,
    'fontCss': originalFontCss(chapter.fontFamily),
  };

  Future<void> _applyStyle(_ChapterFrame frame) async {
    final c = frame.chapter;
    final key =
        '${c.fontSizePx}|${c.columnMarginPx}|${c.indent}|${c.fontFamily}|'
        '${c.fontWeight}|${c.themeColors}|${c.lineHeight}|${c.paragraphGapEm}';
    if (frame.styleKey == key) return;
    frame.styleKey = key;
    if (c.fontFamily.isNotEmpty) {
      await _evaluate(
        frame,
        'window.__gt && __gt.prepareFont(${jsonEncode(c.fontFamily)}, ${jsonEncode(originalFontCss(c.fontFamily))})',
        async: true,
      );
      if (!_alive(frame) || frame.styleKey != key) return;
    }
    await frame.host.applyStyle(
      fontSizePx: c.fontSizePx,
      lineHeight: c.lineHeight,
      paragraphGapEm: c.paragraphGapEm,
      marginPx: c.columnMarginPx,
      indent: c.indent,
      fontFamily: c.fontFamily,
      fontWeight: c.fontWeight,
      colors: c.themeColors,
      initialInformation:
          ReaderDeliveryExperiments.originalConfigure && !frame.paginated
          ? c.information
          : null,
    );
    if (ReaderDeliveryExperiments.originalConfigure && !frame.paginated) {
      frame.informationKey = jsonEncode(c.information);
    }
  }
}
