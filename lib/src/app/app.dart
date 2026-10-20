import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_controller.dart';
import 'app_scope.dart';
import 'home_shell.dart';
import 'theme.dart';

/// 应用根（注入 [AppController]，构建 Material 3 主题）。
class Mp4FixApp extends StatelessWidget {
  const Mp4FixApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AppScope(controller: controller, child: const _AppRoot());
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 去抖后的设置还没来得及落盘就切后台 / 退出 → 立刻补一次，
    // 否则用户刚改的 WebDAV 配置或「记住密码」会丢。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      final controller = AppScope.read(context);
      unawaited(controller.flushSettings());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return MaterialApp(
      title: 'MP4 修复器',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: controller.settings.themeMode,
      locale: const Locale('zh'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // 系统字号很大时限制放大上限，避免表单被撑到一屏放不下
      // （工具类界面：1.0~1.25 倍之间跟随系统）
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 1.0,
        maxScaleFactor: 1.25,
        child: child!,
      ),
      home: const HomeShell(),
    );
  }
}
