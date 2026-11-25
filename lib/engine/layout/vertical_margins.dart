import 'dart:math' as math;

/// Must keep both extremes until every adjoining edge has been considered.
/// Collapsing (30, -20) to 10 first would give the wrong result when 25 joins.
class VerticalMargin {
  const VerticalMargin(this.positive, this.negative);
  const VerticalMargin.zero() : this(0, 0);
  factory VerticalMargin.of(double size) =>
      size >= 0 ? VerticalMargin(size, 0) : VerticalMargin(0, size);

  final double positive, negative;
  double get extent => positive + negative;

  VerticalMargin join(VerticalMargin other) => VerticalMargin(
    math.max(positive, other.positive),
    math.min(negative, other.negative),
  );
}

class BlockMargins {
  const BlockMargins(this.before, this.after, {this.through = false});

  final VerticalMargin before, after;
  final bool through;
}

/// One enclosing box. Edges that are on a different fragment are inactive.
typedef VerticalBox = ({
  int id,
  bool first,
  bool last,
  double before,
  double after,
  double insetTop,
  double insetBottom,
  bool separatesTop,
  bool separatesBottom,
});

/// Solve each end from the outside in. The first group belongs to the
/// surrounding flow. Later groups and all padding belong inside the fragment.
({VerticalMargin outside, double inside, Map<int, double> edges})
layoutVerticalEdge(List<VerticalBox> boxes, {required bool leading}) {
  final groups = <VerticalMargin>[const VerticalMargin.zero()];
  final positions = <int, (int, double)>{};
  var padding = 0.0;
  for (final box in boxes) {
    if (!(leading ? box.first : box.last)) continue;
    groups.last = groups.last.join(
      VerticalMargin.of(leading ? box.before : box.after),
    );
    positions[box.id] = (groups.length - 1, padding);
    final inset = leading ? box.insetTop : box.insetBottom;
    padding += inset;
    if (inset != 0 || (leading ? box.separatesTop : box.separatesBottom)) {
      groups.add(const VerticalMargin.zero());
    }
  }
  final inside = [0.0];
  for (final group in groups.skip(1)) {
    inside.add(inside.last + group.extent);
  }
  return (
    outside: groups.first,
    inside: padding + inside.last,
    edges: {
      for (final MapEntry(key: id, value: (group, padding))
          in positions.entries)
        id: padding + inside[group],
    },
  );
}
