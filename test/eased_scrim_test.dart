import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/utils/eased_scrim.dart';

/// The grid's footer scrim drew a hard horizontal line across the rows at the
/// point where it began. Nothing there stepped: a two-stop gradient is a
/// straight line in alpha, so the *value* was continuous and only the slope
/// was not -- flat above the scrim, then falling at a constant rate from the
/// very next row. That is the condition for Mach banding, and the eye duly
/// drew the edge in.
///
/// So the guard is about slope, not about value. An eased ramp has to arrive
/// at each end flat enough that the join has no edge left to read.
void main() {
  /// Alpha per unit of gradient length, across each pair of adjacent stops.
  List<double> slopesOf(LinearGradient g) {
    return <double>[
      for (int i = 1; i < g.colors.length; i++)
        (g.colors[i].a - g.colors[i - 1].a) / (g.stops![i] - g.stops![i - 1]),
    ];
  }

  group('easedScrim', () {
    test('spans exactly the requested alphas', () {
      final g = easedScrim(const Color(0xFF102030), 0.0, 0.85);

      expect(g.colors.first.a, closeTo(0.0, 0.001));
      expect(g.colors.last.a, closeTo(0.85, 0.001));
      expect(g.stops!.first, 0.0);
      expect(g.stops!.last, 1.0);
      expect(g.colors.length, g.stops!.length);
    });

    test('keeps the scrim colour and only varies its alpha', () {
      const colour = Color(0xFF102030);
      final g = easedScrim(colour, 0.0, 0.85);

      for (final c in g.colors) {
        expect(c.r, colour.r);
        expect(c.g, colour.g);
        expect(c.b, colour.b);
      }
    });

    test('never lightens on the way down', () {
      final slopes = slopesOf(easedScrim(const Color(0xFF102030), 0.0, 0.85));

      // A non-monotonic ramp would show as a band of its own.
      for (final s in slopes) {
        expect(s, greaterThanOrEqualTo(0.0));
      }
    });

    test('arrives at both ends far flatter than it runs in the middle', () {
      final slopes = slopesOf(easedScrim(const Color(0xFF102030), 0.0, 0.85));
      final steepest = slopes.reduce((a, b) => a > b ? a : b);

      // The join is what draws the line, so this is the assertion that
      // matters: a straight ramp would make every one of these equal.
      expect(slopes.first, lessThan(steepest / 3));
      expect(slopes.last, lessThan(steepest / 3));
    });

    test('two segments chained at a wash join smoothly', () {
      // How the grid footer builds it: a tail down to the wash, then a band
      // from the wash to opaque. The join is a seam the eye can find just as
      // easily as the top edge, so it has to be flat from both sides.
      const wash = 0.85;
      final tail = slopesOf(easedScrim(const Color(0xFF102030), 0.0, wash));
      final band = slopesOf(easedScrim(const Color(0xFF102030), wash, 1.0));

      expect(tail.last, lessThan(tail.reduce((a, b) => a > b ? a : b) / 3));
      expect(band.first, lessThan(band.reduce((a, b) => a > b ? a : b) / 3));

      // And the segments meet at the same alpha, so nothing steps at the seam.
      expect(band.isNotEmpty, isTrue);
      final tailEnd = easedScrim(
        const Color(0xFF102030),
        0.0,
        wash,
      ).colors.last;
      final bandStart = easedScrim(
        const Color(0xFF102030),
        wash,
        1.0,
      ).colors.first;
      expect(tailEnd.a, closeTo(bandStart.a, 0.001));
    });
  });
}
