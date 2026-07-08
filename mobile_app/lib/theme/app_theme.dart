import 'package:flutter/material.dart';

/// Background gradient colors that adapt to light/dark theme.
class AppBackground extends ThemeExtension<AppBackground> {
  final Color gradientStart;
  final Color gradientMid;
  final Color gradientEnd;

  const AppBackground({
    required this.gradientStart,
    required this.gradientMid,
    required this.gradientEnd,
  });

  List<Color> get gradientColors => [gradientStart, gradientMid, gradientEnd];

  @override
  AppBackground copyWith({
    Color? gradientStart,
    Color? gradientMid,
    Color? gradientEnd,
  }) {
    return AppBackground(
      gradientStart: gradientStart ?? this.gradientStart,
      gradientMid: gradientMid ?? this.gradientMid,
      gradientEnd: gradientEnd ?? this.gradientEnd,
    );
  }

  @override
  AppBackground lerp(ThemeExtension<AppBackground>? other, double t) {
    if (other is! AppBackground) return this;
    return AppBackground(
      gradientStart: Color.lerp(gradientStart, other.gradientStart, t)!,
      gradientMid: Color.lerp(gradientMid, other.gradientMid, t)!,
      gradientEnd: Color.lerp(gradientEnd, other.gradientEnd, t)!,
    );
  }
}

const _darkSeed = Colors.blue;
const _lightSeed = Colors.blue;

final darkTheme = ThemeData.dark().copyWith(
  scaffoldBackgroundColor: Colors.transparent,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _darkSeed,
    brightness: Brightness.dark,
  ),
  extensions: const [
    AppBackground(
      gradientStart: Color(0xFF000000),
      gradientMid: Color(0xFF000000),
      gradientEnd: Color(0xFF000000),
    ),
  ],
);

final lightTheme = ThemeData.light().copyWith(
  scaffoldBackgroundColor: Colors.transparent,
  colorScheme: ColorScheme.fromSeed(
    seedColor: _lightSeed,
    brightness: Brightness.light,
  ),
  extensions: const [
    AppBackground(
      gradientStart: Color(0xFFf0f4f8),
      gradientMid: Color(0xFFe8eef5),
      gradientEnd: Color(0xFFdce4ed),
    ),
  ],
);
