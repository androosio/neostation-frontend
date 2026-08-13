import 'dart:ui' as ui;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter/material.dart';

/// A performant, dependency-free frosted-glass surface.
///
/// It replicates the cheap "frosted" path of the liquid-glass packages we
/// evaluated: a single engine [BackdropFilter] blur pass over a translucent
/// tint, clipped to the panel's own shape, with a hairline border and a
/// canvas-drawn specular rim.
///
/// Deliberately does NOT do the expensive parts of a full liquid-glass
/// package — refraction, distortion, chromatic aberration and the shader that
/// re-samples the live backdrop every frame. Those shader passes are what made
/// the previous dependency heavy on low-end GPUs (Android TV included). The
/// engine blur is optimized and clipped to the small panel area, so this stays
/// cheap even when the content behind the glass changes every frame.
class NeoGlass extends StatelessWidget {
  const NeoGlass({
    super.key,
    required this.child,
    this.cornerRadius = 14,
    this.blur = 3,
    this.tint,
    this.padding,
    this.rimIntensity = 0.5,
  });

  final Widget child;

  /// Corner radius of the glass panel.
  final double cornerRadius;

  /// Gaussian blur sigma applied to the backdrop.
  ///
  /// `0` disables the blur entirely — the surface becomes a flat translucent
  /// panel (the cheapest mode, zero backdrop cost). Keep it modest on low-end
  /// GPUs; the cost scales with the blurred area.
  final double blur;

  /// Translucent fill tinted over the blurred backdrop. Defaults to a
  /// scaffold-background tint.
  final Color? tint;

  /// Inset applied inside the glass around [child].
  final EdgeInsetsGeometry? padding;

  /// Strength of the specular rim highlight (0.0–1.0). The rim blends with the
  /// image behind the glass, so it appears as the backdrop colour lifted
  /// brighter.
  final double rimIntensity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Semi-transparent so the image behind shows through and the rim (drawn
    // beneath it) glows with the backdrop's colours.
    final glassTint =
        tint ?? theme.scaffoldBackgroundColor.withValues(alpha: 0.8);
    final borderRadius = BorderRadius.circular(cornerRadius);

    // Layered so the rim can sit OUTSIDE the card:
    //  1. the frosted surface is clipped to the rounded shape
    //  2. the rim is painted over/around it (blend modes reach the backdrop
    //     image behind the card), extending beyond the card's edge.
    Widget surface = ColoredBox(
      color: glassTint,
      child: padding != null ? Padding(padding: padding!, child: child) : child,
    );

    // One engine blur pass over the backdrop, clipped to the panel shape.
    // This is the whole "frost" — no refraction shader, no per-frame capture.
    //
    // `.grouped` shares ONE backdrop snapshot with every other grouped filter
    // under the nearest [BackdropGroup]. Ungrouped, each panel's blur pass
    // re-reads the whole scene, so cost scales with the NUMBER of glass
    // surfaces rather than their area — and this chrome puts eight on screen
    // at once. The constructor resolves the ancestor via
    // `BackdropGroup.of(context)?.backdropKey`, so it degrades safely to an
    // unshared snapshot when no group is in scope.
    if (blur > 0) {
      surface = BackdropFilter.grouped(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: surface,
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRRect(borderRadius: borderRadius, child: surface),
        // External rim: drawn outside the clipped surface so the border sits
        // around the card, blending with the backdrop image behind it.
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _GlassRimPainter(
                cornerRadius: cornerRadius,
                intensity: rimIntensity,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints the glass rim: a soft specular highlight sweeping with the light
/// direction plus a sharp inner edge, matching how the liquid-glass packages
/// shade their borders — but in plain Canvas.
class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({required this.cornerRadius, required this.intensity});

  final double cornerRadius;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0) return;

    // Rounded-rect outline offset OUTWARD by half the stroke width, so the
    // whole border sits outside the card's edge (external, not inset/middle).
    // The rim is painted outside the ClipRRect, so nothing clips it.
    Path outsetOutline(double strokeWidth) {
      final extent = strokeWidth / 2;
      final rect = (Offset.zero & size).inflate(extent);
      return Path()..addRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(cornerRadius + extent)),
      );
    }

    final bounds = Offset.zero & size;

    // Light from the top-left. The rim stays light all around — it only fades
    // in strength towards the far edge, it never turns dark.
    final light = Alignment.topLeft;
    final sweep = LinearGradient(
      begin: light,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: 0.60 * intensity),
        Colors.white.withValues(alpha: 0.40 * intensity),
        Colors.white.withValues(alpha: 0.20 * intensity),
        Colors.white.withValues(alpha: 0.35 * intensity),
      ],
      stops: const [0.0, 0.3, 0.6, 0.9],
    ).createShader(bounds);

    // Pass 1: soft outer glow — composited with BlendMode.overlay over the
    // image behind the glass, so the edge reads as the backdrop colour lifted
    // brighter (overlay preserves the hue instead of washing it to white).
    canvas.drawPath(
      outsetOutline(1.2.h),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2.h
        ..isAntiAlias = true
        ..blendMode = BlendMode.overlay
        ..shader = sweep,
    );

    // Pass 2: sharper inner border line — backdrop-tinted via overlay, brightest
    // near the light and fading to a faint highlight on the far side.
    canvas.drawPath(
      outsetOutline(0.9.h),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9.h
        ..isAntiAlias = true
        ..blendMode = BlendMode.overlay
        ..shader = LinearGradient(
          begin: light,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.70 * intensity),
            Colors.white.withValues(alpha: 0.35 * intensity),
            Colors.white.withValues(alpha: 0.20 * intensity),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(bounds),
    );
  }

  @override
  bool shouldRepaint(_GlassRimPainter oldDelegate) =>
      oldDelegate.cornerRadius != cornerRadius ||
      oldDelegate.intensity != intensity;
}
