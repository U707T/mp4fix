import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/engine/engine.dart';

import 'support/mp4_sampler.dart';

/// **「无损」不变量测试**：对每个夹具，逐轨道比较
/// 样本数 / 大小 / 时间戳 / 描述索引 / **载荷字节（按样本顺序拼接）**，
/// 修复前后的结果必须完全一致；输出还必须是 faststart 且健康。
///
/// 采样表由 `support/mp4_sampler.dart` **独立实现**解析（不复用被测引擎的代码），
/// 避免"用同一份代码验证自己"。
void main() {
  const fixtures = [
    'good.mp4',
    'bad_interleave.mp4',
    'bad_interleave_v1mdhd.mp4',
    'moov_last.mp4',
    'co64.mp4',
  ];

  int fnv1a(Uint8List bytes) {
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  for (final name in fixtures) {
    test('无损不变式：$name', () {
      final input = File('test/fixtures/$name');
      final out = File(
        '${Directory.systemTemp.path}/mp4fix-lossless-'
        '${DateTime.now().microsecondsSinceEpoch}-$name',
      );
      try {
        final seekable = FileSeekableInput(input);
        final sink = FileSyncSink(out.openSync(mode: FileMode.write));
        try {
          Mp4Repair.repair(seekable, sink);
        } finally {
          sink.close();
          seekable.close();
        }

        final before = Mp4Sampler.read(input);
        final after = Mp4Sampler.read(out);
        expect(after.length, before.length, reason: '轨道数发生变化');

        final rafA = input.openSync();
        final rafB = out.openSync();
        try {
          for (var i = 0; i < before.length; i++) {
            final a = before[i];
            final b = after[i];
            expect(b.timescale, a.timescale, reason: '轨道 $i 的 timescale');
            expect(b.count, a.count, reason: '轨道 $i 的样本数');
            expect(b.sizes, orderedEquals(a.sizes), reason: '轨道 $i 的样本大小');
            expect(b.dts, orderedEquals(a.dts), reason: '轨道 $i 的时间戳');
            expect(b.descIdx, orderedEquals(a.descIdx), reason: '轨道 $i 的描述索引');

            final pa = a.payload(rafA);
            final pb = b.payload(rafB);
            expect(pb.length, pa.length, reason: '轨道 $i 的载荷总字节数');
            if (fnv1a(pb) != fnv1a(pa)) {
              // 失败时再逐字节比较，给出可定位的差异
              expect(pb, orderedEquals(pa), reason: '轨道 $i 的载荷字节必须逐字节一致');
            }
          }
        } finally {
          rafA.closeSync();
          rafB.closeSync();
        }

        final check = FileSeekableInput(out);
        try {
          final report = Mp4Inspect.inspect(check, interleaveThresholdBytes: 20000);
          expect(report.health, Mp4Health.ok, reason: report.detail);
          expect(report.faststart, isTrue, reason: '修复产物应 moov 前置');
        } finally {
          check.close();
        }
      } finally {
        if (out.existsSync()) out.deleteSync();
      }
    });
  }
}
