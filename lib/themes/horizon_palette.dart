import 'package:flutter/material.dart';

const Color _primaryColor = Color(0xFFEC6A88);
const Color _onPrimaryColor = Color(0xFF16161C);
const Color _secondaryColor = Color(0xFFFBC3A7);
const Color _onSecondaryColor = Color(0xFF16161C);
const Color _tertiaryColor = Color(0xFFF7CCD2);
const Color _onTertiaryColor = Color(0xFF252029);
final Color _surfaceColor = HSLColor.fromColor(
  const Color(0xFF1C1E26),
).withLightness(0.25).toColor();
const Color _onSurfaceColor = Color(0xFFFADAD1);
const Color _errorColor = Color(0xFFEC6A88);
const Color _onErrorColor = Color(0xFF16161C);
const Color _outlineColor = Color(0xFF3D3F4B);
const Color _shadowColor = Color(0xFF000000);

const Color _backgroundColor = Color(0xFF1C1E26);

const Color _batteryFull = Color(0xFF3FDAA4);
const Color _batteryMedium = Color(0xFFFBC3A7);
const Color _batteryLow = Color(0xFFEC6A88);
const Color _batteryPower = Color(0xFF3FC6DE);

const Color _warningColor = Color(0xFFFBC3A7);
const Color _onWarningColor = Color(0xFF16161C);
const Color _successColor = Color(0xFF3FDAA4);
const Color _onSuccessColor = Color(0xFF16161C);
const Color _infoColor = Color(0xFF3FC6DE);
const Color _onInfoColor = Color(0xFF16161C);

final ThemeData horizonPalette = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.dark(
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

class HorizonCustomColors {
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
