# TaleTin 图标库

本目录包含 UI 参考图中使用的通用操作图标、状态图标和成就符号，共 66 个 SVG。

## 视觉规范

- 画布：`24 × 24`，默认在 24dp 容器中显示。
- 线条：多数图标使用 `1.75` 线宽、圆角端点和圆角连接。
- 颜色：使用 `currentColor`，由 Flutter 主题在运行时设置；文件内不写死业务颜色。
- 交互：图标视觉尺寸可小于按钮，但 Android 点击区域不得小于 `48 × 48dp`。
- 状态：选中、错误、成功不能只靠颜色，需同时使用文字、形状或状态图标。
- 例外：`more-vertical.svg` 使用实心圆点，`drag-handle.svg` 使用更粗线条，以保证小尺寸辨识度。

## 分类

- 导航与通用操作：`arrow-back`、`chevron-*`、`close`、`more-vertical`、`check`、`plus`、`minus`、`search`、`sort`、`grid`、`list`、`drag-handle`。
- 主导航与书架：`books`、`trophy`、`settings`、`folder-plus`、`bookmark`、`toc`。
- 阅读控制：`brightness`、`font`、`headphones`、`auto-read`、`locator`、`sun-low`、`sun-high`、`reset`、`battery`、`screen-on`。
- 播放与听书：`play`、`pause`、`skip-previous`、`skip-next`、`step-previous`、`step-next`、`voice`、`gauge`、`clock`、`waveform`。
- 设置与数据：`palette`、`sparkles`、`eye`、`page`、`database`、`broom`、`export`、`restore`、`file`、`document-text`、`info`。
- 导入与状态：`check-circle`、`alert-circle`、`lock`、`retry`。
- 笔记与成就：`note`、`note-plus`、`highlight`、`trash`、`calendar`、`open-book`、`leaf`、`lantern`、`moon-stars`、`award`。

## Flutter 接入约定

`pubspec.yaml` 已声明整个 `assets/icons/` 目录。阶段 0 实现 UI 时再选择并锁定 SVG 渲染依赖；渲染时通过主题色覆盖 `currentColor`。带可见文字的装饰图标不重复朗读，独立图标按钮必须提供明确的语义标签和选中/展开状态。
