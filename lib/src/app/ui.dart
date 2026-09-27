import 'package:flutter/material.dart';

import 'models.dart';

/// 统一包裹可能抛错的异步操作：失败时用 SnackBar 提示（不打断界面）。
///
/// 界面里所有"点一下就干活"的入口都应经过它，避免异常冒泡成未处理错误。
Future<void> guardUi(
  BuildContext context,
  Future<void> Function() action, {
  void Function(Object error)? onError,
}) async {
  try {
    await action();
  } catch (e) {
    onError?.call(e);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(describeError(e))),
    );
  }
}
