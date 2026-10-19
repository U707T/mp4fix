import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/output_target.dart';

/// 「就地覆盖绝不破坏原文件」的回归。
///
/// 覆盖是**不可逆**操作：文件夹页默认「没选输出文件夹 → 就地覆盖输入文件夹」，
/// 一旦把坏产物写回去，用户的原片就没了。这里把两道闸都钉死：
///  1. [validateRepairOutput] 必须挡住空文件 / 截断 / 非 MP4 / 大小不符；
///  2. [DirectoryOutputTarget.save] 落位失败时必须把旧文件还原。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mp4fix-safe'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File fixture(String name) => File('test/fixtures/$name');

  group('产物校验：不合格就不许覆盖', () {
    test('空文件被挡住', () {
      final f = File('${dir.path}/empty.mp4')..writeAsBytesSync(const []);
      expect(validateRepairOutput(f), contains('0 字节'));
    });

    test('截断文件被挡住（结构损坏）', () {
      final f = File('${dir.path}/trunc.mp4')
        ..writeAsBytesSync(fixture('truncated.mp4').readAsBytesSync());
      expect(validateRepairOutput(f), isNotNull, reason: '截断文件不该通过校验');
    });

    test('非 MP4 垃圾被挡住', () {
      final f = File('${dir.path}/junk.mp4')
        ..writeAsBytesSync(List<int>.filled(4096, 0x41));
      expect(validateRepairOutput(f), isNotNull);
    });

    test('大小与预期不符被挡住（引擎半途失败的典型症状）', () {
      final f = File('${dir.path}/ok.mp4')
        ..writeAsBytesSync(fixture('good.mp4').readAsBytesSync());
      final realSize = f.lengthSync();
      expect(
        validateRepairOutput(f, expectedBytes: realSize + 12345),
        contains('大小不符'),
      );
    });

    test('合格的修复产物通过校验', () {
      final f = File('${dir.path}/good.mp4')
        ..writeAsBytesSync(fixture('good.mp4').readAsBytesSync());
      expect(validateRepairOutput(f, expectedBytes: f.lengthSync()), isNull);
    });

    test('不存在文件被挡住', () {
      expect(validateRepairOutput(File('${dir.path}/nope.mp4')), isNotNull);
    });
  });

  group('就地覆盖：失败必须还原原文件', () {
    test('正常覆盖：内容换成新的、无 .bak 残留', () async {
      final target = File('${dir.path}/a.mp4')
        ..writeAsBytesSync(fixture('good.mp4').readAsBytesSync());
      final newBytes = fixture('bad_interleave.mp4').readAsBytesSync();
      final src = File('${dir.path}/.tmp-src')..writeAsBytesSync(newBytes);

      await DirectoryOutputTarget(dir).save(src, 'a.mp4');

      expect(target.readAsBytesSync(), newBytes);
      expect(File('${target.path}.mp4fix-bak').existsSync(), isFalse);
    });

    test('落位失败：原文件字节级不变（数据不丢）', () async {
      final original = fixture('good.mp4').readAsBytesSync();
      final target = File('${dir.path}/b.mp4')..writeAsBytesSync(original);
      // 用目录冒充源文件 → rename / copy 必然失败
      final badSource = Directory('${dir.path}/bad-src')..createSync();

      await expectLater(
        DirectoryOutputTarget(dir).save(File(badSource.path), 'b.mp4'),
        throwsA(isA<FileSystemException>()),
      );

      expect(target.existsSync(), isTrue, reason: '原文件必须还在');
      expect(
        target.readAsBytesSync(),
        original,
        reason: '原文件必须字节级不变 —— 这是「绝不破坏原文件」的底线',
      );
      expect(File('${target.path}.mp4fix-bak').existsSync(), isFalse);
    });
  });
}
