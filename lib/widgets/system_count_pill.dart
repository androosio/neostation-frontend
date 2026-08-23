import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../models/my_systems.dart';
import '../utils/count_label.dart';
import 'core_footer.dart';
import 'footer_label_pill.dart';

/// The focused system's count, floating where a footer would have put it.
///
/// The carousel view has no footer row: its cards are height-bound, so every
/// row of chrome under them costs the artwork both height *and* width. This
/// keeps the count without the row — the pill floats over the view, and the
/// carousel behind it keeps the full height.
///
/// It is deliberately placed to land exactly where [SystemsGridFooter]'s pill
/// does, so switching between grid and carousel does not move the count.
/// [floating] wraps it in the [Positioned] that does that; the widget itself
/// is just the pill.
class SystemCountPill extends StatelessWidget {
  /// The focused card. A recent-game card has no count, so it renders nothing
  /// rather than inventing one.
  final SystemInfo system;

  const SystemCountPill({super.key, required this.system});

  /// This pill anchored to the bottom left of a [Stack], in the band a
  /// [CoreFooter] would occupy.
  static Widget floating(SystemInfo system) => Positioned(
    left: 12.r,
    bottom: 0,
    height: kCoreFooterHeight.r,
    // Nothing here is interactive, and the carousel underneath handles drags
    // that start anywhere in the view — the pull-to-rescan gesture included.
    child: IgnorePointer(
      child: Center(child: SystemCountPill(system: system)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (system.isGame) return const SizedBox.shrink();
    return FooterLabelPill(label: systemCountLabel(context, system));
  }
}
