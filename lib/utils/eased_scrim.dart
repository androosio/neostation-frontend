import 'package:flutter/material.dart';

/// Smoothstep, `t^2 * (3 - 2t)`, sampled at eight even steps: flat at both
/// ends, steepest through the middle.
const List<double> kEasedScrimSamples = <double>[
  0.0,
  0.043,
  0.156,
  0.316,
  0.5,
  0.684,
  0.844,
  0.957,
  1.0,
];

/// A vertical scrim that *eases* from one alpha of [color] to another, rather
/// than running straight between them.
///
/// A two-stop gradient is a straight line in alpha. That is continuous in
/// value but not in slope: above the scrim alpha is flat, and from one row to
/// the next it starts falling at a constant rate. The eye reads an abrupt
/// change of slope as an edge -- Mach banding -- so a straight ramp draws a
/// hard horizontal line where it begins, even though no pixel there steps.
/// (Measured on the grid footer's scrim: the ramp itself was smooth to within
/// noise, and the line sat exactly at the row where the slope turned on.)
///
/// Smoothstep flattens the ramp at both ends, so where a scrim meets untouched
/// content -- or meets the next segment of itself -- there is no change in
/// slope left to see. The cost is a steeper middle, which is unproblematic:
/// the eye keys on the discontinuity, not on the gradient's magnitude.
///
/// Segments chained end to end (`0 -> wash`, then `wash -> 1`) are therefore
/// smooth across the join as well, which is why the caller can measure the
/// second segment's height at layout time instead of computing stops for one
/// long gradient by hand.
LinearGradient easedScrim(Color color, double from, double to) {
  return LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      for (final t in kEasedScrimSamples)
        color.withValues(alpha: from + (to - from) * t),
    ],
    stops: <double>[
      for (int i = 0; i < kEasedScrimSamples.length; i++)
        i / (kEasedScrimSamples.length - 1),
    ],
  );
}
