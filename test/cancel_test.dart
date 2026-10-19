import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/app_controller.dart';
import 'package:mp4fix/src/app/models.dart';

/// 「停止」按钮的回归。
///
/// 事故：`_setRunning()` 无条件把 `_cancelRequested` 置回 false，而任务结束时的
/// `_setRunning(null)` 也会走这条路径。于是 `scanFolder(fixAfterScan: true)`
/// 在 finally 里复位状态之后，`if (fixAfterScan && !_cancelRequested)` 永远成立：
/// 用户点了「停止」，扫描停下，然后**立刻又照着扫到的列表开始批量修复**。
void main() {
  test('任务结束时复位运行状态，但不能顺手把「已取消」擦掉', () {
    final c = AppController();

    c.debugSetRunning(JobSource.folder);
    expect(c.running, isTrue);
    expect(c.cancelRequested, isFalse);

    c.requestCancel();
    expect(c.cancelRequested, isTrue);

    // 任务收尾：复位 running —— 取消标记必须留着，
    // 调用方还要靠它决定「要不要接着 fixAfterScan」
    c.debugSetRunning(null);
    expect(c.running, isFalse);
    expect(
      c.cancelRequested,
      isTrue,
      reason: '复位 running 时擦掉取消标记 → 扫描后仍会自动开始修复',
    );
  });

  test('开始新任务时才清掉上一次的取消标记', () {
    final c = AppController();

    c.debugSetRunning(JobSource.folder);
    c.requestCancel();
    c.debugSetRunning(null);
    expect(c.cancelRequested, isTrue);

    c.debugSetRunning(JobSource.local);
    expect(c.cancelRequested, isFalse, reason: '新任务应当从干净状态开始');
  });

  test('没有任务在跑时 requestCancel 是空操作', () {
    final c = AppController();
    c.requestCancel();
    expect(c.cancelRequested, isFalse);
  });
}
