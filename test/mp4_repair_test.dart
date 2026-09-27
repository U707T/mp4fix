import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/engine/engine.dart';

/// Mp4Repair 基础回归测试（保护既有引擎行为）。
void main() {
  File fixture(String name) => File('test/fixtures/$name');

  File tempOut(String prefix) => File(
      '${Directory.systemTemp.path}/$prefix-${DateTime.now().microsecondsSinceEpoch}.mp4');

  RepairStats repairToFile(
    String name,
    File out, {
    bool Function()? isCancelled,
  }) {
    final input = FileSeekableInput(fixture(name));
    final sink = FileSyncSink(out.openSync(mode: FileMode.write));
    try {
      return Mp4Repair.repair(input, sink, isCancelled: isCancelled);
    } finally {
      sink.close();
      input.close();
    }
  }

  InspectReport inspectFile(File f) {
    final input = FileSeekableInput(f);
    try {
      return Mp4Inspect.inspect(input);
    } finally {
      input.close();
    }
  }

  test('repairKeepsSampleCounts', () {
    final out = tempOut('mp4fix-repair');
    try {
      final stats = repairToFile('good.mp4', out);
      expect(stats.trackCount, 2);
      expect(stats.payloadBytes > 0, isTrue);
      expect(stats.outputBytes > stats.payloadBytes, isTrue);
      expect(stats.moovBytes > 0, isTrue);

      final r = inspectFile(out);
      expect(r.health, Mp4Health.ok, reason: r.detail);
      expect(r.videoSamples, 75);
      expect(r.audioSamples, 217);
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  });

  /// 回归：视频轨 `mdhd` 为 v1 的文件必须能**真正重排**。
  /// 此前 timescale 被按 64 位读成垃圾值 → 视频块时间≈0 → 排序退化成"视频全在前、音频全在后"，
  /// 修复结果与原件几乎一致（等于没修）。
  test('repairVersion1MdhdFileActuallyInterleaves', () {
    final out = tempOut('mp4fix-v1');
    try {
      repairToFile('bad_interleave_v1mdhd.mp4', out);
      final r = inspectFile(out);
      expect(r.health, Mp4Health.ok, reason: r.detail);
      expect(r.videoSamples, 75);
      expect(r.audioSamples, 217);
      expect(r.interleaveMaxBytes < 20000, isTrue,
          reason: 'max=${r.interleaveMaxBytes}');
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  });

  test('repairOfTruncatedFileThrows', () {
    final out = tempOut('mp4fix-repair');
    try {
      expect(
        () => repairToFile('truncated.mp4', out),
        throwsA(isA<RepairException>()),
      );
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  });

  test('repairHonorsCancellation', () {
    final out = tempOut('mp4fix-repair');
    try {
      expect(
        () => repairToFile('good.mp4', out, isCancelled: () => true),
        throwsA(isA<RepairCancelledException>()),
      );
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  });
}
