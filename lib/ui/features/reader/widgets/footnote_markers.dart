/// 注释编号的文字身份。括号只影响显示，不改变同一编号的身份；
/// 此处不负责把普通数字链接判为脚注，链接身份仍由来源与上下文决定。
String? noteMarkerKey(String text) {
  var value = text.trim();
  const pairs = {'[': ']', '(': ')', '（': '）', '【': '】'};
  while (value.length >= 2 && pairs[value[0]] == value[value.length - 1]) {
    value = value.substring(1, value.length - 1).trim();
  }
  const superscripts = '⁰¹²³⁴⁵⁶⁷⁸⁹';
  // 圈码是编号本身，保留数字身份，兼容正文圈码与注释普通数字的往返。
  const circled = [
    '①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳',
    '㉑㉒㉓㉔㉕㉖㉗㉘㉙㉚㉛㉜㉝㉞㉟',
    '㊱㊲㊳㊴㊵㊶㊷㊸㊹㊺㊻㊼㊽㊾㊿',
    '❶❷❸❹❺❻❼❽❾❿',
    '➀➁➂➃➄➅➆➇➈➉',
    '⓵⓶⓷⓸⓹⓺⓻⓼⓽⓾',
  ];
  for (var i = 0; i < circled.length; i++) {
    final at = circled[i].indexOf(value);
    if (value.length == 1 && at >= 0) {
      return '${at + (i == 1
              ? 21
              : i == 2
              ? 36
              : 1)}';
    }
  }
  value = value.split('').map((c) {
    final index = superscripts.indexOf(c);
    return index < 0 ? c : '$index';
  }).join();
  return RegExp(
        r'^(?:\d{1,4}|注[a-z]{1,3})$',
        caseSensitive: false,
      ).hasMatch(value)
      ? value.toLowerCase()
      : null;
}

/// 独立空锚点后只接紧邻的编号注释，不能跳到下一段找一个看似合适的编号。
bool startsWithNoteMarker(String text) => RegExp(
  r'^[\[（(【\s]*(?:[①-⑳㉑-㉟㊱-㊿❶-❿➀-➉⓵-⓾]|(?:\d{1,4}|[⁰¹²³⁴⁵⁶⁷⁸⁹]{1,4}|注[a-z]{1,3})(?:[\]）)】.、\s]|$))',
  caseSensitive: false,
).hasMatch(text.trimLeft());

bool onlyNoteOpeningBrackets(String text) =>
    RegExp(r'^[\[（(【\s]+$').hasMatch(text);

String stripLeadingBracketedNoteMarker(String text) {
  final prefix = RegExp(
    r'^[\[（(【]+\s*(?:\d{1,4}|[⁰¹²³⁴⁵⁶⁷⁸⁹]{1,4}|注[a-z]{1,3})\s*[\]）)】]+\s*',
    caseSensitive: false,
  ).firstMatch(text);
  return prefix != null && noteMarkerKey(prefix.group(0)!) != null
      ? text.substring(prefix.end)
      : text;
}
