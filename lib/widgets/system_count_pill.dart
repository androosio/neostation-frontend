import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../models/my_systems.dart';
import '../utils/count_label.dart';
import 'core_footer.dart';
import 'footer_label_pill.dart';

/// The focused card's label, floating where a footer would have put it.
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
///
/// A recent-game card has no count to give — it is one game — so it puts the
/// game's name here instead. That card carries its name only as wheel artwork,
/// which not every game has and which nothing falls back to when it is
/// missing; its own footer strip is spent on the play time. The band was
/// simply empty for it before.
class SystemCountPill extends StatelessWidget {
  /// The focused card: a system, or the recent-game card at the head of the
  /// carousel.
  final SystemInfo system;

  const SystemCountPill({super.key, required this.system});

  /// How much of the view the pill may take before its label ellipsizes.
  ///
  /// The pill was unbounded while it only ever said "1234 Games": a
  /// [Positioned] with a `left` and no `right` hands its child infinite width,
  /// so [FooterLabelPill]'s `Flexible` and its ellipsis were both inert. A game
  /// name is long enough to reach the edge of the screen and would simply have
  /// run off it.
  static const double _maxWidthFraction = 0.5;

  /// The pill at the start of its slot, capped so a long label ellipsizes
  /// instead of running the width of the view.
  ///
  /// Left-aligned rather than centred: the slot is the whole band, and the pill
  /// belongs at its start.
  ///
  /// Both views go through here — [floating] for the carousel, and
  /// [SystemsGridFooter] for the grid — so the label and its width can only be
  /// changed for both at once.
  static Widget bounded(SystemInfo system) => Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: ScreenUtil().screenWidth * _maxWidthFraction,
      ),
      child: SystemCountPill(system: system),
    ),
  );

  /// This pill anchored to the bottom left of a [Stack], in the band a
  /// [CoreFooter] would occupy.
  static Widget floating(SystemInfo system) => Positioned(
    left: 12.r,
    right: 12.r,
    bottom: 0,
    height: kCoreFooterHeight.r,
    // Nothing here is interactive, and the carousel underneath handles drags
    // that start anywhere in the view — the pull-to-rescan gesture included.
    child: IgnorePointer(child: bounded(system)),
  );

  @override
  Widget build(BuildContext context) {
    // The recent-game card is a single game, so "1 Game" would be a label that
    // says nothing. Its name goes here instead. Still nothing rather than an
    // empty pill if the card somehow has no title, which is the state this
    // branch used to render for every game card.
    if (system.isGame) {
      final String name = system.title ?? '';
      if (name.isEmpty) return const SizedBox.shrink();
      return FooterLabelPill(label: name);
    }
    return FooterLabelPill(label: systemCountLabel(context, system));
  }
}
