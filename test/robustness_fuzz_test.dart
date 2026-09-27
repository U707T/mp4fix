import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/engine/engine.dart';

/// 健壮性（模糊测试，固定种子可复现）：
///   - 检测 `Mp4Inspect.inspect` **绝不抛异常**（损坏文件必须给出报告）；
///   - 修复 `Mp4Repair.repair` 只能抛 [RepairException]（不能是 RangeError / OOM 等 Error）；
///   - 不得出现超大内存分配（表长度自洽校验的回归保护）。
void main() {
  final base = File('test/fixtures/good.mp4');

  void check(Uint8List bytes, String label) {
    // 1) 检测：必须返回报告
    final input = BytesSeekableInput(bytes);
    InspectReport report;
    try {
      report = Mp4Inspect.inspect(input);
    } catch (e) {
      fail('$label：Mp4Inspect 抛出了异常（应返回报告）：$e');
    } finally {
      input.close();
    }
    expect(report.health, isA<Mp4Health>(), reason: label);

    // 2) 修复：要么成功，要么抛可捕获的 RepairException
    final input2 = BytesSeekableInput(bytes);
    final sink = BytesSyncSink();
    try {
      Mp4Repair.repair(input2, sink);
    } on RepairException {
      // 预期路径：损坏文件 → 明确报错
    } on RepairCancelledException {
      fail('$label：修复不应被取消');
    } catch (e) {
      fail('$label：修复抛出了非预期异常（${e.runtimeType}）：$e');
    } finally {
      input2.close();
    }
  }

  test('随机字节破坏 ×120（固定种子）', () {
    final random = Random(20260927);
    final original = base.readAsBytesSync();
    for (var i = 0; i < 120; i++) {
      final bytes = Uint8List.fromList(original);
      final mutations = 1 + random.nextInt(4);
      for (var m = 0; m < mutations; m++) {
        // 一半落在文件头/moov 区，一半全随机
        final pos = random.nextBool()
            ? random.nextInt(min(8192, bytes.length))
            : random.nextInt(bytes.length);
        bytes[pos] = random.nextInt(256);
      }
      check(bytes, '破坏#$i');
    }
  });

  test('随机截断 ×60（固定种子）', () {
    final random = Random(4242);
    final original = base.readAsBytesSync();
    for (var i = 0; i < 60; i++) {
      final cut = 16 + random.nextInt(original.length - 16);
      check(Uint8List.fromList(original.sublist(0, cut)), '截断@$cut');
    }
  });

  test('纯随机数据 ×30（固定种子）', () {
    final random = Random(777);
    for (var i = 0; i < 30; i++) {
      final len = 16 + random.nextInt(20000);
      final bytes = Uint8List(len);
      for (var j = 0; j < len; j++) {
        bytes[j] = random.nextInt(256);
      }
      check(bytes, '随机#$i');
    }
  });
}
