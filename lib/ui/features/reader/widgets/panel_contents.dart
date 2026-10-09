// 保留原导入路径，避免阅读页和现有测试因文件拆分产生额外改动。
export 'contents/contents_panel.dart';
// 行高与字号常量一并导出：测试按字号区分目录里的行，写死的数字会和实现走散。
export 'contents/toc_rows.dart'
    show
        TocRowMetrics,
        chapterFontSize,
        chapterRowVerticalPadding,
        volumeHeaderFontSize,
        volumeHeaderVerticalPadding;
