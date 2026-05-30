import 'package:flutter/material.dart';

const Color _primaryColor = Color(0xFF7273AC);
const Color _onPrimaryColor = Color(0xFFFFFFFF);
const Color _secondaryColor = Color(0xFF32BB92);
const Color _onSecondaryColor = Color(0xFFFFFFFF);
const Color _tertiaryColor = Color(0xFF464158);
const Color _onTertiaryColor = Color(0xFFc2c0d5);
final Color _surfaceColor = HSLColor.fromColor(
  const Color(0xFFDFDDE4),
).withLightness(0.85).toColor();
const Color _onSurfaceColor = Color(0xFF5A5875);
const Color _errorColor = Color(0xFFFF5252);
const Color _onErrorColor = Color(0xFFFFFFFF);
const Color _outlineColor = Color(0xFFE0E0E0);
const Color _shadowColor = Color(0x1A000000);

const Color _backgroundColor = Color(0xFFc2c0d5);

const Color _batteryFull = Color(0xFF32BB92);
const Color _batteryMedium = Color(0xFFD16003);
const Color _batteryLow = Color(0xFFDC2626);
const Color _batteryPower = Color(0xFF0284C7);

const Color _warningColor = Color(0xFFD16003);
const Color _onWarningColor = Color(0xFFFFFFFF);
const Color _successColor = Color(0xFF32BB92);
const Color _onSuccessColor = Color(0xFFFFFFFF);
const Color _infoColor = Color(0xFF0284C7);
const Color _onInfoColor = Color(0xFFFFFFFF);

final ThemeData nslightPalette = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.light(
    primary: _primaryColor,
    secondary: _secondaryColor,
    tertiary: _tertiaryColor,
    surface: _surfaceColor,

    onPrimary: _onPrimaryColor,
    onSecondary: _onSecondaryColor,
    onTertiary: _onTertiaryColor,
    onSurface: _onSurfaceColor,

    error: _errorColor,
    onError: _onErrorColor,
    outline: _outlineColor,
    shadow: _shadowColor,
  ),

  cardColor: _backgroundColor,
  scaffoldBackgroundColor: _backgroundColor,

  textTheme: TextTheme(
    displayLarge: TextStyle(
      color: _onSurfaceColor,
      fontSize: 32,
      fontWeight: FontWeight.bold,
    ),
    titleLarge: TextStyle(
      color: _onSurfaceColor,
      fontSize: 24,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: TextStyle(
      color: _onSurfaceColor,
      fontSize: 18,
      fontWeight: FontWeight.w500,
    ),

    bodyLarge: TextStyle(color: _onSurfaceColor, fontSize: 16),
    bodyMedium: TextStyle(color: _onSurfaceColor, fontSize: 14),
    bodySmall: TextStyle(color: _onSurfaceColor, fontSize: 12),

    labelLarge: TextStyle(
      color: _onSurfaceColor,
      fontSize: 14,
      fontWeight: FontWeight.w500,
    ),
  ),
);

class NSlightCustomColors {
  Color get batteryFull => _batteryFull;
  Color get batteryMedium => _batteryMedium;
  Color get batteryLow => _batteryLow;
  Color get batteryPower => _batteryPower;

  Color get errorColor => _errorColor;
  Color get onErrorColor => _onErrorColor;

  Color get successColor => _successColor;
  Color get onSuccessColor => _onSuccessColor;

  Color get infoColor => _infoColor;
  Color get onInfoColor => _onInfoColor;

  Color get warningColor => _warningColor;
  Color get onWarningColor => _onWarningColor;
}
