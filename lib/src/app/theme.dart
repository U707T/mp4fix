import 'package:flutter/material.dart';

/// 品牌主色（跟随 Material 3 动态取色前的基础色）。
const Color kSeedColor = Color(0xFF3D6BFF);

/// 构建 Material 3 主题。
ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: kSeedColor,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // 工具类应用：整体收紧一档密度（控件更矮、更紧凑），避免"UI 太大"
    visualDensity: VisualDensity.compact,
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      toolbarHeight: 52,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
  );
}
