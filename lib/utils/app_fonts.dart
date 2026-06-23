import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// A selectable UI font family.
///
/// Each option couples the persisted [key] (stored in the user config and
/// database) with a human-facing [label] and the Google Fonts builder used to
/// apply it to the global [TextTheme].
class AppFontOption {
  const AppFontOption({
    required this.key,
    required this.label,
    required this.apply,
  });

  /// Stable identifier persisted in [ConfigModel.appFont] / the database.
  final String key;

  /// Display name shown in the font picker.
  final String label;

  /// Applies this font family on top of the provided base [TextTheme].
  final TextTheme Function(TextTheme base) apply;
}

/// Central catalog of the fonts the user can choose from in Settings.
///
/// The first entry ('default') is the app's original face (Anta) and is used
/// as the fallback for any unknown/legacy persisted value.
class AppFonts {
  AppFonts._();

  /// Key of the default font option.
  static const String defaultKey = 'default';

  /// Ordered list of available fonts, as displayed in the picker.
  static final List<AppFontOption> options = [
    AppFontOption(
      key: 'default',
      label: 'Default',
      apply: (base) => GoogleFonts.antaTextTheme(base),
    ),
    AppFontOption(
      key: 'chakra_petch',
      label: 'Chakra Petch',
      apply: (base) => GoogleFonts.chakraPetchTextTheme(base),
    ),
    AppFontOption(
      key: 'orbitron',
      label: 'Orbitron',
      apply: (base) => GoogleFonts.orbitronTextTheme(base),
    ),
    AppFontOption(
      key: 'rajdhani',
      label: 'Rajdhani',
      apply: (base) => GoogleFonts.rajdhaniTextTheme(base),
    ),
  ];

  /// Resolves the option for [key], falling back to the default font.
  static AppFontOption resolve(String? key) {
    return options.firstWhere((o) => o.key == key, orElse: () => options.first);
  }

  /// Applies the font identified by [key] on top of the base [TextTheme].
  static TextTheme apply(String? key, TextTheme base) =>
      resolve(key).apply(base);

  /// Human-facing label for [key] (falls back to the default font's label).
  static String labelFor(String? key) => resolve(key).label;
}
