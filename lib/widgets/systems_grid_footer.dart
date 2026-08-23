import 'package:flutter/material.dart';
import 'package:neostation/models/my_systems.dart';
import 'package:neostation/utils/count_label.dart';
import 'core_footer.dart';
import 'footer_label_pill.dart';

/// The systems **grid**'s footer: the focused card's count, bottom left.
///
/// The carousel has no footer at all — its cards are large enough to carry
/// their own count under the logo. A grid card is not: its artwork is a fixed
/// square, so the strip left under it is roughly half the carousel's, and a
/// count row there shrinks the system logo to something smaller than the count
/// itself. The count comes off the card in this view and lives here instead,
/// which is what the strip was doing before it was removed.
///
/// Only the count. The system name is the card's own label repeated, and Enter
/// duplicated both A on a pad and a tap on the selected card, so neither came
/// back with it; Settings is on the card's Y / long-press menu.
class SystemsGridFooter extends CoreFooter {
  /// The focused card. A recent-game card has no count, so the footer is empty
  /// for it rather than inventing one — the row keeps its height either way,
  /// so the grid above does not resize as the selection moves.
  final SystemInfo system;

  const SystemsGridFooter({super.key, required this.system});

  @override
  bool get centerControls => false;

  @override
  bool get showVersion => false;

  @override
  Widget? buildLeftContent(BuildContext context) {
    if (system.isGame) return null;
    return FooterLabelPill(label: systemCountLabel(context, system));
  }

  @override
  List<Widget> buildControls(BuildContext context) => const [];
}
