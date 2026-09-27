import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/engine/engine.dart';

/// Mp4Inspect 检测器测试（夹具与 Kotlin 版一致）：
///  - good.mp4            : 正常交错、faststart
///  - bad_interleave.mp4  : 视频块全部排在音频块之前（交错距离 ≈ 68KB, 而 good ≈ 4KB）
///  - truncated.mp4       : 尾部被截断（mdat 部分缺失）
///
/// 小文件的实际距离远小于 4MB 默认阈值, 因此区分测试使用 20KB 的较小阈值;
/// 默认阈值行为另有专门用例覆盖。
void main() {
  File fixture(String name) => File('test/fixtures/$name');

  InspectReport inspect(
    String name, {
    int threshold = Mp4Inspect.defaultInterleaveThreshold,
  }) {
    final input = FileSeekableInput(fixture(name));
    try {
      return Mp4Inspect.inspect(input, interleaveThresholdBytes: threshold);
    } finally {
      input.close();
    }
  }

  test('goodFileIsHealthy', () {
    final r = inspect('good.mp4');
    expect(r.health, Mp4Health.ok, reason: r.detail);
    expect(r.faststart, isTrue);
    expect(r.trackCount, 2);
    expect(r.videoSamples, 75);
    expect(r.audioSamples, 217);
    expect(r.interleaveMaxBytes < 20000, isTrue,
        reason: 'max=${r.interleaveMaxBytes}');
  });

  test('badInterleaveDetectedWithThreshold', () {
    final good = inspect('good.mp4', threshold: 20000);
    final bad = inspect('bad_interleave.mp4', threshold: 20000);
    expect(good.health, Mp4Health.ok, reason: good.detail);
    expect(bad.health, Mp4Health.needsReinterleave, reason: bad.detail);
    expect(bad.interleaveMaxBytes >= 20000, isTrue);
    expect(
      bad.interleaveMaxBytes > good.interleaveMaxBytes * 5,
      isTrue,
      reason: 'bad=${bad.interleaveMaxBytes} good=${good.interleaveMaxBytes}',
    );
  });

  test('version1MdhdTimescaleParsedCorrectly', () {
    // 回归：mdhd v1 里 creation/modification 是 64 位，但 timescale 仍是 32 位（偏移 28）。
    // 曾经按 64 位读 → timescale 变成 ts*2^32+… 的垃圾值 → 视频块时间≈0 → 判定失效。
    final good = inspect('good_v1mdhd.mp4', threshold: 20000);
    expect(good.health, Mp4Health.ok, reason: good.detail);
    expect(good.interleaveMaxBytes < 20000, isTrue,
        reason: 'max=${good.interleaveMaxBytes}');

    final bad = inspect('bad_interleave_v1mdhd.mp4', threshold: 20000);
    expect(bad.health, Mp4Health.needsReinterleave, reason: bad.detail);
    expect(bad.interleaveMaxBytes >= 20000, isTrue);
  });

  test('defaultThresholdKeepsSmallFixtureBelow', () {
    // 面向大文件的默认阈值下, 小夹具即使重排过也不应触发（避免误报）
    expect(inspect('bad_interleave.mp4').health, Mp4Health.ok);
  });

  test('truncatedFileIsCorrupt', () {
    final r = inspect('truncated.mp4');
    expect(r.health, Mp4Health.corrupt, reason: r.detail);
    expect(
      r.detail.contains('截断') ||
          r.detail.contains('越界') ||
          r.detail.contains('损坏'),
      isTrue,
      reason: r.detail,
    );
  });

  test('repairedFileIsHealthyAndInterleaveIsTight', () {
    final out = File('${Directory.systemTemp.path}/mp4fix-inspect-${DateTime.now().microsecondsSinceEpoch}.mp4');
    try {
      final input = FileSeekableInput(fixture('bad_interleave.mp4'));
      final sink = FileSyncSink(out.openSync(mode: FileMode.write));
      try {
        Mp4Repair.repair(input, sink);
      } finally {
        sink.close();
        input.close();
      }

      final fixed = FileSeekableInput(out);
      late final InspectReport r;
      try {
        r = Mp4Inspect.inspect(fixed, interleaveThresholdBytes: 20000);
      } finally {
        fixed.close();
      }
      expect(r.health, Mp4Health.ok, reason: r.detail);
      expect(r.faststart, isTrue);
      expect(r.videoSamples, 75);
      expect(r.audioSamples, 217);

      final bad = inspect('bad_interleave.mp4', threshold: 20000);
      expect(
        r.interleaveMaxBytes < bad.interleaveMaxBytes / 3,
        isTrue,
        reason: 'fixed=${r.interleaveMaxBytes} bad=${bad.interleaveMaxBytes}',
      );
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  });
}
