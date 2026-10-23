import '../../normalization/locator_mapper.dart';

/// Keep import metadata and on-demand fallback on identical anchor/UTF-16 rules.
Set<String> anchorCandidates(Iterable<String> fragments) {
  final wanted = fragments.toSet();
  for (final fragment in wanted.toList()) {
    if (!fragment.contains('%')) continue;
    try {
      wanted.add(Uri.decodeComponent(fragment));
    } on FormatException {
      /* Old encoded anchor fallback remains unchanged. */
    } on ArgumentError {
      /* Incomplete percent escapes are not valid anchors. */
    }
  }
  return wanted;
}

Map<String, double?>? decodeAnchorPositions(
  Map<String, dynamic> data,
  Iterable<String> fragments,
) {
  if (data['ok'] != true) return null;
  final points = data['points'] as Map, blocks = data['blocks'] as Map;
  final total = data['total'] as int;
  double? position(String raw) {
    var value = raw;
    if (!points.containsKey(value) && raw.contains('%')) {
      try {
        value = Uri.decodeComponent(raw);
      } on FormatException {
        return null;
      } on ArgumentError {
        return null;
      }
    }
    final point = points[value] as List?;
    if (point == null) return null;
    final block = blocks[point[0]] as List;
    final offset = snapToGrapheme(block[1] as String, point[1] as int);
    // Match the existing calculation order, including double rounding.
    return total == 0 ? 0 : (block[0] as int) / total + offset / total;
  }

  return {for (final fragment in fragments) fragment: position(fragment)};
}
