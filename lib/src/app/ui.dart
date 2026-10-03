import 'package:flutter/material.dart';

import 'app_controller.dart';
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

/// 「全部处理」：连判定为「正常」的视频也一起无损重排 —— 先说清楚再动手。
Future<void> runProcessAll(
  BuildContext context,
  AppController controller,
  JobSource source,
) async {
  final total = controller.processAllCount(source);
  if (total == 0) return;
  final normal = controller.normalCount(source);
  final fixable = controller.fixableCount(source);

  if (normal > 0) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('全部处理 $total 个视频？'),
        content: Text(
          '其中 $fixable 个是问题文件；$normal 个判定为「正常」的也会一起重排。\n\n'
          '正常的视频本来就能正常播放，重排只是把它们按时间重新排整齐'
          '（不重新编码、画质无损），代价是多花一些时间。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('全部处理'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
  }

  await guardUi(
  context,
  () => source == JobSource.webdav
      ? controller.fixWebDavJobs(processAll: true)
      : controller.fixJobs(source, processAll: true),
  );
}
