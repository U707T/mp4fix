import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/output_target.dart';

/// 「SAF 落位失败必须还原原文件」的回归（v2.7.0 数据事故）。
///
/// 事故现场：用户报告修复后文件夹里全是 `xxx.mp4.mp4fix-bak`，正式名不见了。
/// 原因在 Kotlin 侧 `writeToTree()`：原文件改名让位后，`.part → 正式名` 这一步
/// 在部分 SAF 提供方（百度网盘等）上「返回成功但实际没改名」，随后备份被删/没还原，
/// 原视频就永久停在 `.bak`。
///
/// 修复后 Kotlin 侧的顺序与不变式：
///  1. 写 .part → 校验大小（此时原文件毫发无伤）
///  2. 原文件改名 .bak，**改名后必须 findChild 复核**；复核不到就中止、原文件不动
///  3. .part → 正式名，**不信返回值，改用 findChild 复核**
///  4. 任何失败 → `restoreBackup()` 把 .bak 改回正式名
///  5. 只有确认正式名已就位，才删 .bak
///
/// Kotlin 侧无法在 Dart 测试里直接跑，所以这里用「桌面目录落位」把**同一套语义**
/// 钉死：失败必须还原、成功才清理、绝不出现「原文件只剩 .bak」的终态。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mp4fix-bak'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File fixture(String n) => File('test/fixtures/$n');

  test('成功落位：不留 .bak、不留 .part', () async {
    final target = File('${dir.path}/a.mp4')
      ..writeAsBytesSync(fixture('good.mp4').readAsBytesSync());
    final src = File('${dir.path}/.src')
      ..writeAsBytesSync(fixture('bad_interleave.mp4').readAsBytesSync());

    await DirectoryOutputTarget(dir).save(src, 'a.mp4');

    expect(target.existsSync(), isTrue);
    expect(File('${target.path}.mp4fix-bak').existsSync(), isFalse);
    expect(
      dir.listSync().where((e) => e.path.contains('.mp4fix-')),
      isEmpty,
      reason: '落位完成后不该留下任何 .mp4fix-* 中间文件',
    );
  });

  test('失败落位：原文件回到正式名，且不留 .bak', () async {
    final original = fixture('good.mp4').readAsBytesSync();
    final target = File('${dir.path}/b.mp4')..writeAsBytesSync(original);
    final badSource = Directory('${dir.path}/bad')..createSync();

    await expectLater(
      DirectoryOutputTarget(dir).save(File(badSource.path), 'b.mp4'),
      throwsA(anything),
    );

    // 关键不变式：正式名必须存在，内容字节级不变
    expect(target.existsSync(), isTrue, reason: '原文件不能消失');
    expect(target.readAsBytesSync(), original);
    expect(
      File('${target.path}.mp4fix-bak').existsSync(),
      isFalse,
      reason: '还原后不该残留 .bak —— 否则用户看到的就是一堆 .bak',
    );
  });

  test('绝不产生「只有 .bak、没有正式名」的终态', () async {
    final original = fixture('good.mp4').readAsBytesSync();
    final target = File('${dir.path}/c.mp4')..writeAsBytesSync(original);
    final badSource = Directory('${dir.path}/bad2')..createSync();

    try {
      await DirectoryOutputTarget(dir).save(File(badSource.path), 'c.mp4');
    } catch (_) {
      // 预期失败
    }

    final bak = File('${target.path}.mp4fix-bak');
    final hasBakOnly = bak.existsSync() && !target.existsSync();
    expect(
      hasBakOnly,
      isFalse,
      reason: '这是 v2.7.0 数据事故的形态：正式名消失、只剩 .bak',
    );
  });
}
