import 'package:flutter/widgets.dart';

import 'app_controller.dart';

/// 通过 [InheritedNotifier] 提供 [AppController]（用 Flutter 自带能力，无需额外状态库）。
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({
    super.key,
    required AppController controller,
    required super.child,
  }) : super(notifier: controller);

  /// 取到控制器并订阅其变更（控制器 notify 时调用方会重建）。
  static AppController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载');
    return scope!.notifier!;
  }
}
