import 'dart:ui';

final _languageCode = RegExp(r'^[a-zA-Z]{2,8}$');
final _scriptCode = RegExp(r'^[a-zA-Z]{4}$');
final _regionCode = RegExp(r'^(?:[a-zA-Z]{2}|[0-9]{3})$');

/// 排版只需要 BCP 47 的语言、文字和地区三个部分；扩展子标记保留在来源样式。
Locale? bookLocale(String? tag) {
  if (tag == null || tag.isEmpty) return null;
  final parts = tag.replaceAll('_', '-').split('-');
  final language = parts.first;
  if (!_languageCode.hasMatch(language)) return null;
  String? script, region;
  for (final part in parts.skip(1)) {
    if (part.length == 1) break;
    if (script == null && _scriptCode.hasMatch(part)) {
      script = part[0].toUpperCase() + part.substring(1).toLowerCase();
    } else if (region == null && _regionCode.hasMatch(part)) {
      region = part.toUpperCase();
    }
  }
  return Locale.fromSubtags(
    languageCode: language.toLowerCase(),
    scriptCode: script,
    countryCode: region,
  );
}
