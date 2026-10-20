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

  /// 只读一次、**不建立依赖**（生命周期回调 / 事件处理里用）。
  ///
  /// [of] 会注册依赖，只能在 build / didChangeDependencies 里调用；
  /// 在 `didChangeAppLifecycleState` 这类地方用它会被断言拦住。
  static AppController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载');
    return scope!.notifier!;
  }
}
