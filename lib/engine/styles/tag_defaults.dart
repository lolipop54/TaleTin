/// 标签默认表：作者没写样式时，每个 HTML 标签长什么样。
///
/// 为什么需要这张表：浏览器有一套自己的默认样式（UA stylesheet），但我们不能直接
/// 拿来用——那套默认里有 `p { margin: 1em 0 }`、`h2 { font-size: 1.5em }` 之类，
/// 会和阅读器的段距、字号设置叠在一起，最后「书的段距 + 浏览器段距」变成双倍留白。
/// 所以我们自己写一张**显式**的表：哪个标签默认多粗、留多少间距，都在这里。
///
/// 三条规矩：
/// 1. 这张表是第 2 层，作者样式表（第 3 层）和行内样式（第 4 层）都能覆盖它；
/// 2. 表里的值是**原始 CSS 写法**（`1.5em`、`bold`、`0 .67em`），由同一套解析器
///    解析，不在这里写死像素，也不会出现「Dart 一份、Rust 一份」；
/// 3. 正文的段落间距、首行缩进、行高不写进这张表：它们由阅读器设置决定，
///    写进来就会和读者设置叠加。标题字号同理：标题 = 正文 + 固定像素差，
///    由排版层统一计算，不在这张表里另写一份倍数。
///
/// 这张表由 `tool/style_tables_gen.dart` 生成一份 Rust 常量表，两个转换器用同一份数据。
library;

abstract final class TagDefaults {
  /// 表自身的版本；改动标签默认值时必须递增，进正文缓存身份。
  ///
  /// 2：h1～h6 不再写字号（标题字号改为阅读器规则：正文 + 固定像素差）。
  /// 3：`<code>` 明确写成行内。它的来源角色同时服务块级 `<pre>` 和行内
  ///    `<code>`，只按角色判断会把行内代码当成块级，白底和内边距都会丢。
  /// 4：hr 使用浏览器默认的凹边框与外边距。
  static const int version = 4;

  /// 标题行高。标题不跟随正文行高：2.2 倍行高放在标题上太散。
  ///
  /// 这是引擎默认值，不是 CSS 的 `normal`；写在这里是为了让「标题行高」
  /// 只有一个落点，而不是散在 `layout_options.dart` 的常量里。
  static const String headingLineHeight = '1.35';

  /// 代码块字号与行高：比正文略小、行距略紧。
  static const String codeFontSize = '0.9em';

  /// 上下标字号（相对正文）。
  ///
  /// 浏览器默认是 `smaller`（约 0.83），引擎历史实现用 0.72；
  /// 脚注编号在 0.72 时更不容易顶到上一行，保留历史值。
  static const String scriptFontSize = '0.72em';

  /// 引用块左右缩进（两字）。
  static const String quoteIndent = '2em';

  /// 列表项缩进（一档）。第一级要放得下「1.」这样的标记。
  static const String listIndent = '1.6em';

  /// 标签 → 默认声明。顺序只影响同一元素内的声明先后，不影响不同标签。
  static const Map<String, Map<String, String>> table = {
    'html': {'display': 'block', 'margin': '0', 'padding': '0'},
    'body': {'display': 'block', 'margin': '0', 'padding': '0'},
    // 正文段落不写 margin：段距由读者设置决定，写 0 只是说明「标签本身不加留白」。
    'p': {'display': 'block', 'margin': '0'},

    // 标题：块级、粗体、固定行高与上下留白。
    // 字号**不写**：标题按阅读器规则「正文 + 固定像素差」计算
    // （`layout_options.dart` 的 `_headingSizeDelta`）。写进表里就成了第二份定义，
    // 将来做 CSS 层叠时会和固定差值乘在一起，标题会突然变很大。
    'h1': {
      'display': 'block',
      'font-weight': 'bold',
      'line-height': headingLineHeight,
      'margin': '0.67em 0',
    },
    'h2': {
      'display': 'block',
      'font-weight': 'bold',
      'line-height': headingLineHeight,
      'margin': '0.83em 0',
    },
    'h3': {
      'display': 'block',
      'font-weight': 'bold',
      'line-height': headingLineHeight,
      'margin': '1em 0',
    },
    'h4': {
      'display': 'block',
      'font-weight': 'bold',
      'line-height': headingLineHeight,
      'margin': '1.33em 0',
    },
    'h5': {
      'display': 'block',
      'font-weight': 'bold',
      'line-height': headingLineHeight,
      'margin': '1.67em 0',
    },
    'h6': {
      'display': 'block',
      'font-weight': 'bold',
      'line-height': headingLineHeight,
      'margin': '2.33em 0',
    },

    'blockquote': {'display': 'block', 'margin': '0 $quoteIndent'},
    'pre': {
      'display': 'block',
      'white-space': 'pre',
      'font-family': 'monospace',
      'font-size': codeFontSize,
    },
    // 行内代码：display 必须显式写出来，不能靠「code 角色是不是容器」猜
    //（同一个角色也用于块级 `<pre>`）。书里写 display:block 时照常覆盖。
    'code': {'display': 'inline', 'font-family': 'monospace'},
    'kbd': {'font-family': 'monospace'},
    'samp': {'font-family': 'monospace'},

    'ul': {
      'display': 'block',
      'margin': '1em 0',
      'padding-left': listIndent,
      'list-style-type': 'disc',
    },
    'ol': {
      'display': 'block',
      'margin': '1em 0',
      'padding-left': listIndent,
      'list-style-type': 'decimal',
    },
    'li': {'display': 'list-item', 'margin': '0'},
    'dl': {'display': 'block', 'margin': '1em 0'},
    'dt': {'display': 'block', 'font-weight': 'bold'},
    'dd': {'display': 'block', 'margin': '0 0 0 2em'},

    'figure': {'display': 'block', 'margin': '1em 0'},
    'figcaption': {
      'display': 'block',
      'font-size': '0.9em',
      'text-align': 'center',
    },
    // 浏览器默认 hr 是一个浅灰凹边框盒；作者 CSS 仍可覆盖每个属性。
    // Chromium 对未指定边框色的 hr 使用特殊浅灰绘制，#eee 的凹边框与实测像素一致。
    'hr': {
      'display': 'block',
      'color': 'gray',
      'border-style': 'inset',
      'border-width': '1px',
      'border-color': '#eeeeee',
      'margin': '0.5em auto',
      'overflow': 'hidden',
    },

    'table': {'display': 'table'},
    'caption': {
      'display': 'table-caption',
      'font-size': '0.9em',
      'text-align': 'center',
    },
    'thead': {'display': 'table-header-group'},
    'tbody': {'display': 'table-row-group'},
    'tfoot': {'display': 'table-footer-group'},
    'tr': {'display': 'table-row'},
    'td': {'display': 'table-cell'},
    'th': {
      'display': 'table-cell',
      'font-weight': 'bold',
      'text-align': 'center',
    },

    'sup': {'vertical-align': 'super', 'font-size': scriptFontSize},
    'sub': {'vertical-align': 'sub', 'font-size': scriptFontSize},
    'small': {'font-size': '0.85em'},
    'big': {'font-size': '1.2em'},

    'b': {'font-weight': 'bold'},
    'strong': {'font-weight': 'bold'},
    'i': {'font-style': 'italic'},
    'em': {'font-style': 'italic'},
    'u': {'text-decoration': 'underline'},
    'ins': {'text-decoration': 'underline'},
    's': {'text-decoration': 'line-through'},
    'del': {'text-decoration': 'line-through'},
    'strike': {'text-decoration': 'line-through'},

    // 产品确认：所有 <a> 默认加下划线（含脚注引用），书里写 none 才取消。
    'a': {'text-decoration': 'underline'},
    'center': {'display': 'block', 'text-align': 'center'},
  };

  /// 某个标签的默认声明；没有登记过的标签返回 null（按「没有默认样式」处理，
  /// 不猜成段落）。
  static Map<String, String>? forTag(String tag) => table[tag.toLowerCase()];

  /// 稳定顺序的标签列表，导出给 Rust 时保证两次生成结果一致。
  static List<String> get tags => table.keys.toList()..sort();

  /// 导出给 Rust 生成器与覆盖报告。
  static Map<String, Object?> exportJson() => {
    'v': version,
    'tags': {for (final tag in tags) tag: table[tag]},
  };
}
