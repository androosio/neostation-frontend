import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../l10n/app_locale.dart';
import 'core_footer.dart';
import 'footer_label_pill.dart';

/// Footer for the RomM browser's platform and ROM views.
///
/// Same shape and styling as [SystemsGridFooter] — focused item in a pill on
/// the left, gamepad controls on the right — so the remote library reads like
/// the local one. Only the controls differ: the ROM view adds an X view-mode
/// toggle, and both views offer B to step back.
class RommBrowseFooter extends CoreFooter {
  /// Name shown in the pill: the focused platform, or the open platform /
  /// collection while its ROMs are being browsed.
  final String label;

  /// Optional count chip (e.g. "128 games").
  final String? countText;

  /// Label for the A button — "Enter" in the platform view, "Download" in the
  /// ROM view.
  final String confirmLabel;
  final VoidCallback onConfirm;
  final VoidCallback onBack;

  /// Grid/list toggle (X). Null in views that have only one layout.
  final VoidCallback? onToggleView;

  const RommBrowseFooter({
    super.key,
    required this.label,
    required this.confirmLabel,
    required this.onConfirm,
    required this.onBack,
    this.countText,
    this.onToggleView,
  });

  @override
  bool get centerControls => false;

  @override
  bool get showVersion => false;

  @override
  Widget? buildLeftContent(BuildContext context) =>
      FooterLabelPill(label: label, countText: countText);

  @override
  List<Widget> buildControls(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // A sits far right in every footer in the app, so the confirm action is
    // always in the same place; the lesser actions queue up to its left.
    return [
      // Secondary action, styled like the systems footer's Settings button.
      if (onToggleView != null) ...[
        GamepadControl(
          label: AppLocale.hintViewMode.getString(context),
          iconPath: 'assets/images/gamepad/Xbox_X_button.png',
          onTap: onToggleView,
          textColor: scheme.onTertiaryFixed,
          backgroundColor: scheme.tertiaryFixed,
        ),
        SizedBox(width: 8.r),
      ],
      GamepadControl(
        label: AppLocale.hintBack.getString(context),
        iconPath: 'assets/images/gamepad/Xbox_B_button.png',
        onTap: onBack,
        textColor: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
      ),
      SizedBox(width: 8.r),
      GamepadControl(
        label: confirmLabel,
        iconPath: 'assets/images/gamepad/Xbox_A_button.png',
        onTap: onConfirm,
        textColor: scheme.onTertiary,
        backgroundColor: scheme.tertiary,
      ),
    ];
  }
}
