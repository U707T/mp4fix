import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/defaults.dart';
import 'package:mp4fix/src/app/models.dart';
import 'package:mp4fix/src/engine/engine.dart';

/// 「时间 + 字节」双阈值判定的回归。
///
/// 背景：只按字节距离判定会漏判**低码率长视频** —— 一个 300kbps 的片子即使
/// 音视频相隔几十秒，绝对字节距离也可能只有几 MB，永远够不到 4MB 阈值。
/// 时间错位与码率无关，因此改为「任一阈值满足即判需重排」。
void main() {
  File fixture(String name) => File('test/fixtures/$name');

  InspectReport inspect(
    String name, {
    int bytes = Mp4Inspect.defaultInterleaveThreshold,
    double seconds = Mp4Inspect.defaultInterleaveThresholdSeconds,
  }) {
    final input = FileSeekableInput(fixture(name));
    try {
      return Mp4Inspect.inspect(
        input,
        interleaveThresholdBytes: bytes,
        interleaveThresholdSeconds: seconds,
      );
    } finally {
      input.close();
    }
  }

  group('时间维度测量', () {
    test('报告里带时间错位，且与字节距离是两个独立指标', () {
      final r = inspect('bad_interleave.mp4', bytes: 20000);
      // 字节距离 68KB 但时间错位只有 ~23ms（帧间隔的一半）：
      // 说明"块被搬远"不等于"时间上错位"，两个维度确实独立。
      expect(r.interleaveMaxBytes, greaterThan(20000));
      expect(r.interleaveMaxSeconds, greaterThan(0));
      expect(r.interleaveMaxSeconds, lessThan(0.1),
          reason: '时间错位应当很小：${r.interleaveMaxSeconds}');
      expect(r.interleaveMeanSeconds, lessThanOrEqualTo(r.interleaveMaxSeconds));
    });

    test('好文件的时间错位接近 0', () {
      final r = inspect('good.mp4');
      expect(r.interleaveMaxSeconds, lessThan(0.1));
    });
  });

  group('双阈值：任一满足即需重排', () {
    test('字节阈值极大时，仅时间阈值也能触发', () {
      final r = inspect(
        'bad_interleave.mp4',
        bytes: 1 << 40, // 1TB：永远不可能靠字节触发
        seconds: 0.01, // 10ms：时间维度必然触发
      );
      expect(r.health, Mp4Health.needsReinterleave, reason: r.detail);
      expect(r.detail, contains('时间错位'));
    });

    test('两个阈值都很宽松时判正常（不误报）', () {
      final r = inspect('good.mp4', bytes: 1 << 40, seconds: 60);
      expect(r.health, Mp4Health.ok, reason: r.detail);
    });

    test('字节触发、时间不触发 —— 仍是需重排（向后兼容）', () {
      final r = inspect(
        'bad_interleave.mp4',
        bytes: 20000,
        seconds: 60, // 时间维度不参与
      );
      expect(r.health, Mp4Health.needsReinterleave, reason: r.detail);
    });
  });

  group('设置项持久化', () {
    test('thresholdSeconds 能存能读，缺字段回落到默认值', () {
      final s = AppSettings(thresholdSeconds: 0.5);
      final back = AppSettings.fromJson(s.toJson());
      expect(back.thresholdSeconds, 0.5);

      // 老版本存档里没有这个字段 → 用默认值，不能崩
      final legacy = AppSettings.fromJson(const {'thresholdMb': 8});
      expect(legacy.thresholdMb, 8);
      expect(legacy.thresholdSeconds, AppDefaults.thresholdSeconds);
    });

    test('默认值 2 秒（与字节 4MB 配套）', () {
      expect(AppSettings().thresholdSeconds, 2.0);
      expect(AppDefaults.thresholdMb, 4);
    });
  });
}
