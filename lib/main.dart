import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app/app.dart';
import 'src/app/app_controller.dart';

Future<void> main() async {
  // 未处理异常：记录日志并尽量让界面继续可用（而不是直接崩掉）
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint('[mp4fix] FlutterError: ${details.exceptionAsString()}');
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('[mp4fix] Uncaught: $error\n$stack');
        return true;
      };

      final controller = AppController();
      await controller.init();
      runApp(Mp4FixApp(controller: controller));
    },
    (error, stack) => debugPrint('[mp4fix] Zone error: $error\n$stack'),
  );
}
