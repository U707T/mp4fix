import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/engine_tasks.dart';
import 'package:mp4fix/src/engine/engine.dart';

/// 「修复进程意外结束 → 任务必须失败，而不是永远卡在修复中」的回归。
///
/// 事故：`RepairTask.start` 只监听 worker 主动发来的 `done` / `error` 消息。
/// worker 若被系统杀掉、或引擎在 try 之外崩溃，就再也不会发消息，而 `done`
/// 是一个永不完成的 Future —— 界面停在「修复中 63%」，`running` 永远是 true，
/// 所有按钮（添加 / 扫描 / 修复 / 设置）全部变灰，只能杀进程重来。
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('mp4fix-isolate'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('Isolate 意外退出：done 以异常结束（不悬挂）', () async {
    final task = await RepairTask.start(
      inputPath: '${tmp.path}/never-read.mp4',
      outputPath: '${tmp.path}/out.mp4',
      crashForTest: true,
    );
    await expectLater(
      task.done.timeout(const Duration(seconds: 10)),
      throwsA(
        isA<RepairException>().having(
          (e) => e.message,
          'message',
          contains('意外结束'),
        ),
      ),
      reason: '没有 onExit 监听时这里会超时 —— 界面永久卡在「修复中」',
    );
  });

  test('取消后再退出：仍然只报「已取消」，不冒泡成崩溃', () async {
    final task = await RepairTask.start(
      inputPath: '${tmp.path}/never-read.mp4',
      outputPath: '${tmp.path}/out.mp4',
      crashForTest: true,
    );
    task.cancel();
    await expectLater(
      task.done.timeout(const Duration(seconds: 10)),
      throwsA(isA<RepairCancelledException>()),
    );
    expect(task.cancelled, isTrue);
  });

  test('正常路径不受影响：坏文件照样给出可读错误', () async {
    final junk = File('${tmp.path}/junk.mp4')
      ..writeAsBytesSync(List<int>.filled(4096, 7));
    final task = await RepairTask.start(
      inputPath: junk.path,
      outputPath: '${tmp.path}/out.mp4',
    );
    await expectLater(
      task.done.timeout(const Duration(seconds: 10)),
      throwsA(isA<RepairException>()),
    );
  });
}
