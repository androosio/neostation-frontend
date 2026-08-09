/// Geometry for the header strip (`lib/widgets/header.dart`).
///
/// The header is a [Stack] of three independently positioned children — the
/// left dropdown, the centred tab strip, and the right status pill — so nothing
/// structurally stops them colliding. The tab strip is centred on the *screen*,
/// which means every tab added grows it by half a slot on each side while the
/// status pill stays pinned right; enough tabs (or a wide enough clock string)
/// and the two meet.
///
/// These helpers are pure so the arithmetic can be tested without standing up
/// the widget, its providers, and a battery stream. Callers pass values that
/// are already screen-scaled (`.r`).
library;

/// Width of the centred tab strip: an `LB` glyph, the tab pill, and an `RB`
/// glyph.
///
/// Mirrors the widths in `header.dart`: each shoulder button is a 24-wide
/// bumper glyph with 6 of padding either side (36 total), and the pill is 4 of
/// padding either side around [tabCount] slots of [slot] each.
double navStripWidth({
  required int tabCount,
  double slot = 32,
  double shoulder = 36,
  double pillPadding = 4,
}) => (shoulder * 2) + (pillPadding * 2) + (slot * tabCount);

/// Space the right-hand status pill may occupy before it would touch the
/// centred tab strip.
///
/// The strip is centred, so it reaches [navStripWidth] / 2 either side of the
/// midpoint; whatever is left on the right, minus the pill's own [margin] and a
/// visual [gutter], is what the pill can have. Never negative — a strip wider
/// than the screen would otherwise ask for a negative constraint and throw.
double statusPillMaxWidth({
  required double totalWidth,
  required double navStripWidth,
  double margin = 8,
  double gutter = 4,
}) {
  final free = ((totalWidth - navStripWidth) / 2) - margin - gutter;
  return free < 0 ? 0 : free;
}
