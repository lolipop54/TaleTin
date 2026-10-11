# TaleTin 图标库

本目录只保留当前界面使用的 38 个 SVG。底部主导航使用 `assets/icons_used/` 中的 WebP，成就勋章使用 `assets/achievements/` 中的 WebP。

## 视觉规范

- 画布：`24 × 24`，默认在 24dp 容器中显示。
- 线条：多数图标使用 `1.75` 线宽、圆角端点和圆角连接。
- 颜色：使用 `currentColor`，由 Flutter 主题在运行时设置；文件内不写死业务颜色。
- 交互：图标视觉尺寸可小于按钮，但 Android 点击区域不得小于 `48 × 48dp`。
- 状态：选中、错误、成功不能只靠颜色，需同时使用文字、形状或状态图标。
- 例外：`more-vertical.svg` 使用实心圆点，以保证小尺寸辨识度。

## 分类

- 导航与通用操作：`arrow-back`、`chevron-down`、`chevron-left`、`chevron-right`、`close`、`more-vertical`、`check`、`search`、`grid`、`list`。
- 书架与导入：`folder-plus`、`folder`、`folder-input`、`folder-up`、`filter`、`checkbox`、`checkbox-selected`、`caret-down`、`document-text`。
- 阅读控制：`bookmark`、`toc`、`brightness`、`headphones`、`auto-read`、`settings`。
- 播放与听书：`play`、`pause`、`skip-previous`、`skip-next`。
- 选中文字：`palette`、`note`、`note-plus`、`highlight`、`trash`。
- 状态与阅读统计：`check-circle`、`alert-circle`、`lock`、`open-book`。

## Flutter 接入约定

`pubspec.yaml` 已声明整个 `assets/icons/` 目录。图标名在 `lib/ui/core/widgets/gt_icon.dart` 的 `GtIcons` 中登记，通过 `GtIcon` 和 `flutter_svg` 渲染，并用主题色覆盖 `currentColor`。新增或删除素材时同步更新常量和调用处，避免登记不存在的文件。带可见文字的装饰图标不重复朗读，独立图标按钮必须提供明确的语义标签和选中/展开状态。
