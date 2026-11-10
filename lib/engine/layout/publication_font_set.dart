import 'package:flutter/painting.dart';

typedef PublicationFace = ({
  String alias,
  int minWeight,
  int maxWeight,
  bool italic,
});

/// 已在 Flutter 注册的章内字族。别名由实际字体字节生成，可安全写入断点。
class PublicationFontSet {
  const PublicationFontSet(this.families, this.identity);

  static const empty = PublicationFontSet({}, '');
  final Map<String, List<PublicationFace>> families;
  final String identity;

  static const _generic = {
    'serif': 'serif',
    'sans-serif': 'sans-serif',
    'monospace': 'monospace',
    'cursive': 'cursive',
    'fantasy': 'fantasy',
    'system-ui': 'sans-serif',
  };

  TextStyle apply(TextStyle style, List<String>? requested) {
    if (requested == null) return style;
    final weight = style.fontWeight?.value ?? 400;
    final italic = style.fontStyle == FontStyle.italic;
    final candidates = <String>{};
    PublicationFace? primaryFace;
    for (final name in requested) {
      final key = name.toLowerCase();
      final faces = families[key];
      if (faces != null) {
        var best = 1 << 30;
        final matched = <PublicationFace>[];
        for (final face in faces.reversed) {
          final nearest = weight.clamp(face.minWeight, face.maxWeight);
          final score =
              (face.italic == italic ? 0 : 10000) + (weight - nearest).abs();
          if (score > best) continue;
          if (score < best) matched.clear();
          best = score;
          matched.add(face);
        }
        if (candidates.isEmpty) primaryFace = matched.firstOrNull;
        candidates.addAll(matched.map((face) => face.alias));
      } else if (_generic[key] case final family?) {
        candidates.add(family);
      }
    }
    if (candidates.isEmpty) return style;
    if (style.fontFamily case final fallback?) candidates.add(fallback);
    final face = primaryFace;
    return style.copyWith(
      fontFamily: candidates.first,
      fontFamilyFallback: candidates.skip(1).toList(),
      fontVariations: face != null && face.minWeight != face.maxWeight
          ? [
              FontVariation.weight(
                weight.clamp(face.minWeight, face.maxWeight).toDouble(),
              ),
            ]
          : null,
    );
  }
}
