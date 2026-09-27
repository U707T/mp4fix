import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/engine/engine.dart';

/// 引擎加固回归（RC 复查遗留项）：
/// 损坏文件里的"巨大表计数"必须被判为损坏/抛可捕获的异常，
/// 而不是按计数分配超大数组（OutOfMemoryError 属于 Error，`catch (Exception)` 接不住，
/// 会直接把调用线程打崩）。
void main() {
  File fixture(String name) => File('test/fixtures/$name');

  /// 找到 moov > trak > mdia > minf > stbl > stsz 的绝对偏移。
  int findStszOffset(Uint8List bytes) {
    final input = BytesSeekableInput(bytes);
    try {
      final top = readBoxes(input, 0, bytes.length);
      final moov = top.firstWhere((b) => b.type == 'moov');
      final moovChildren = readBoxes(input, moov.payloadStart, moov.end);
      for (final trak in moovChildren.where((b) => b.type == 'trak')) {
        final trakChildren = readBoxes(input, trak.payloadStart, trak.end);
        final mdia = trakChildren.firstWhere((b) => b.type == 'mdia');
        final mdiaChildren = readBoxes(input, mdia.payloadStart, mdia.end);
        final minf = mdiaChildren.firstWhere((b) => b.type == 'minf');
        final minfChildren = readBoxes(input, minf.payloadStart, minf.end);
        final stbl = minfChildren.firstWhere((b) => b.type == 'stbl');
        for (final b in readBoxes(input, stbl.payloadStart, stbl.end)) {
          if (b.type == 'stsz') return b.start;
        }
      }
    } finally {
      input.close();
    }
    fail('夹具里未找到 stsz 盒');
  }

  /// 把 stsz 的 sample_count（盒内偏移 +16）改成 0x7FFFFFFF。
  Uint8List corruptStszCount(String name) {
    final bytes = fixture(name).readAsBytesSync();
    final stsz = findStszOffset(bytes);
    bytes[stsz + 16] = 0x7F;
    bytes[stsz + 17] = 0xFF;
    bytes[stsz + 18] = 0xFF;
    bytes[stsz + 19] = 0xFF;
    return bytes;
  }

  test('损坏的 stsz 计数：检测判为损坏（不崩溃 / 不 OOM）', () {
    final input = BytesSeekableInput(corruptStszCount('good.mp4'));
    try {
      final report = Mp4Inspect.inspect(input);
      expect(report.health, Mp4Health.corrupt, reason: report.detail);
      expect(report.detail, contains('长度异常'), reason: report.detail);
    } finally {
      input.close();
    }
  });

  test('损坏的 stsz 计数：修复抛 RepairException（不崩溃 / 不 OOM）', () {
    final input = BytesSeekableInput(corruptStszCount('bad_interleave.mp4'));
    final sink = BytesSyncSink();
    try {
      expect(
        () => Mp4Repair.repair(input, sink),
        throwsA(isA<RepairException>()),
      );
    } finally {
      input.close();
    }
  });

  test('表长度自洽：正常文件仍然通过', () {
    final input = BytesSeekableInput(fixture('good.mp4').readAsBytesSync());
    try {
      expect(Mp4Inspect.inspect(input).health, Mp4Health.ok);
    } finally {
      input.close();
    }
  });
}
