import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../themes/corner_radii.dart';

/// A tall vertical action button used in the game list / grid / carousel.
///
/// Shows a Material Symbols icon in the upper badge area and a small gamepad
/// hint icon at the bottom, matching the vertical action column style.
class GameActionButton extends StatelessWidget {
  final Key? buttonKey;
  final String iconPath;
  final IconData symbol;
  final Color color;
  final Color? foregroundColor;
  final VoidCallback? onTap;
  final bool isLoading;

  const GameActionButton({
    super.key,
    this.buttonKey,
    required this.iconPath,
    required this.symbol,
    required this.color,
    this.foregroundColor,
    this.onTap,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    const double buttonWidth = 26.0;
    const double buttonHeight = 34.0;
    const double badgeHeight = 18.0;
    const double mainIconSize = 12.0;
    final cornerRadius =
        Theme.of(context).extension<CornerRadii>()?.radiusInternal ??
        BorderRadius.circular(14.r);
    final badgeRadius = BorderRadius.only(
      topLeft: cornerRadius.topLeft,
      topRight: cornerRadius.topRight,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        key: buttonKey,
        onTap: isLoading ? null : onTap,
        borderRadius: cornerRadius,
        child: Container(
          margin: EdgeInsets.only(bottom: 2.r),
          width: buttonWidth.r,
          height: buttonHeight.r,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: cornerRadius,
            border: Border.all(
              color: color,
              width: 2.r,
              strokeAlign: BorderSide.strokeAlignCenter,
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.shadow.withValues(alpha: 0.3),
                blurRadius: 2.r,
                offset: Offset(1.r, 1.r),
              ),
            ],
          ),
          child: isLoading
              ? Center(
                  child: SizedBox(
                    width: 16.r,
                    height: 16.r,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.r,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                )
              : Column(
                  children: [
                    // Action icon badge anchored to the top of the button,
                    // spanning the full width with a low height so it shows
                    // less than half of the button.
                    Container(
                      height: badgeHeight.r,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: badgeRadius,
                      ),
                      child: Center(
                        child: Icon(
                          symbol,
                          size: mainIconSize.r,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    // Gamepad hint icon centered in the lower area.
                    Expanded(
                      child: Center(
                        child: Image.asset(
                          iconPath,
                          width: 14.r,
                          height: 14.r,
                          color: Theme.of(context).colorScheme.onPrimary,
                          colorBlendMode: BlendMode.srcIn,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
