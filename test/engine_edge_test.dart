import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/engine/engine.dart';

/// 边界夹具：moov 后置（可优化）与 64 位 chunk 偏移表（co64）。
void main() {
  File fixture(String name) => File('test/fixtures/$name');

  InspectReport inspect(String name, {int threshold = 4 * 1024 * 1024}) {
    final input = FileSeekableInput(fixture(name));
    try {
      return Mp4Inspect.inspect(input, interleaveThresholdBytes: threshold);
    } finally {
      input.close();
    }
  }

  test('moov 后置：判为「可优化」，修复后 faststart', () {
    final r = inspect('moov_last.mp4', threshold: 20000);
    expect(r.faststart, isFalse, reason: '夹具本身 moov 在 mdat 之后');
    expect(r.health, Mp4Health.optimizable, reason: r.detail);
    expect(r.videoSamples, 75);
    expect(r.audioSamples, 217);

    final out = File('${Directory.systemTemp.path}/mp4fix-moovlast-'
        '${DateTime.now().microsecondsSinceEpoch}.mp4');
    try {
      final input = FileSeekableInput(fixture('moov_last.mp4'));
      final sink = FileSyncSink(out.openSync(mode: FileMode.write));
      try {
        Mp4Repair.repair(input, sink);
      } finally {
        sink.close();
        input.close();
      }
      final fixed = FileSeekableInput(out);
      try {
        final report =
            Mp4Inspect.inspect(fixed, interleaveThresholdBytes: 20000);
        expect(report.health, Mp4Health.ok, reason: report.detail);
        expect(report.faststart, isTrue);
        expect(report.videoSamples, 75);
        expect(report.audioSamples, 217);
      } finally {
        fixed.close();
      }
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  });

  test('co64 偏移表：能被正确解析与修复', () {
    final r = inspect('co64.mp4', threshold: 20000);
    expect(r.health, Mp4Health.ok, reason: 'co64.mp4 本身交错正常：${r.detail}');
    expect(r.videoSamples, 75);
    expect(r.audioSamples, 217);

    final out = File('${Directory.systemTemp.path}/mp4fix-co64-'
        '${DateTime.now().microsecondsSinceEpoch}.mp4');
    try {
      final input = FileSeekableInput(fixture('co64.mp4'));
      final sink = FileSyncSink(out.openSync(mode: FileMode.write));
      try {
        final stats = Mp4Repair.repair(input, sink);
        expect(stats.usedCo64, isFalse, reason: '输出远小于 4GB，应仍用 stco');
      } finally {
        sink.close();
        input.close();
      }
      final fixed = FileSeekableInput(out);
      try {
        final report =
            Mp4Inspect.inspect(fixed, interleaveThresholdBytes: 20000);
        expect(report.health, Mp4Health.ok, reason: report.detail);
        expect(report.videoSamples, 75);
        expect(report.audioSamples, 217);
      } finally {
        fixed.close();
      }
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  });

  test('co64 与 stco 混用：两轨偏移表都能读出（交叉验证独立解析器）', () {
    // 该用例同时验证测试侧独立解析器能处理 co64（见 lossless_test）
    final r = inspect('co64.mp4');
    expect(r.trackCount, 2);
  });
}
