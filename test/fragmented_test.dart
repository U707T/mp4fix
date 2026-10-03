import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/engine/engine.dart';

import 'support/mp4_sampler.dart';

/// 分片（fragmented）MP4 支持测试。
///
/// 夹具：
///  - `fragmented.mp4`     ：ffmpeg 生成的 empty_moov 分片 MP4（8 个 moof）
///  - `fragmented_bad.mp4` ：视频 / 音频数据分居文件两端的“交错极差”重打包版本
///
/// 覆盖：检测分类（可优化 / 需重排）、无损扁平化修复（逐样本比较）、
/// 交错距离改进、取消、截断判定。
void main() {
  File fixture(String name) => File('test/fixtures/$name');

  File tempOut(String prefix) => File(
      '${Directory.systemTemp.path}/$prefix-${DateTime.now().microsecondsSinceEpoch}.mp4');

  InspectReport inspectFile(File f, {int threshold = 4 * 1024 * 1024}) {
    final input = FileSeekableInput(f);
    try {
      return Mp4Inspect.inspect(input, interleaveThresholdBytes: threshold);
    } finally {
      input.close();
    }
  }

  RepairStats repairTo(File src, File out, {bool Function()? isCancelled}) {
    final input = FileSeekableInput(src);
    final sink = FileSyncSink(out.openSync(mode: FileMode.write));
    try {
      return Mp4Repair.repair(input, sink, isCancelled: isCancelled);
    } finally {
      sink.close();
      input.close();
    }
  }

  int fnv1a(Uint8List bytes) {
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h;
  }

  test('检测：分片 MP4 → 默认可优化、低阈值下需重排', () {
    final def = inspectFile(fixture('fragmented.mp4'));
    expect(def.health, Mp4Health.optimizable, reason: def.detail);
    expect(def.faststart, isTrue, reason: def.detail);
    expect(def.trackCount, 2);
    expect(def.videoSamples, 120);
    expect(def.audioSamples, 189);
    expect(def.detail, contains('分片'));
    expect(def.detail, contains('标准 MP4'));

    final low = inspectFile(fixture('fragmented.mp4'), threshold: 20000);
    expect(low.health, Mp4Health.needsReinterleave, reason: low.detail);
    expect(low.interleaveMaxBytes >= 20000, isTrue,
        reason: 'max=${low.interleaveMaxBytes}');
  });

  test('检测：交错极差的分片文件 → 需重排', () {
    final r = inspectFile(fixture('fragmented_bad.mp4'), threshold: 200000);
    expect(r.health, Mp4Health.needsReinterleave, reason: r.detail);
    expect(r.interleaveMaxBytes >= 200000, isTrue,
        reason: 'max=${r.interleaveMaxBytes}');
    expect(r.videoSamples, 120);
    expect(r.audioSamples, 189);
  });

  for (final name in [
    'fragmented.mp4',
    'fragmented_bad.mp4',
    'fragmented_hybrid.mp4',
  ]) {
    test('修复（扁平化）：$name 样本逐字节无损、输出健康且 moov 前置', () {
      final out = tempOut('mp4fix-frag');
      try {
        final stats = repairTo(fixture(name), out);
        expect(stats.trackCount, 2);
        expect(stats.payloadBytes > 0, isTrue);

        final before = Mp4Sampler.read(fixture(name));
        final after = Mp4Sampler.read(out);
        expect(after.length, before.length, reason: '轨道数发生变化');
        expect(before.first.count, 120, reason: '视频样本数');  
        expect(before.last.count, 189, reason: '音频样本数');

        final rafA = fixture(name).openSync();
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
            expect(b.sync, orderedEquals(a.sync), reason: '轨道 $i 的同步标记');

            final pa = a.payload(rafA);
            final pb = b.payload(rafB);
            expect(pb.length, pa.length, reason: '轨道 $i 的载荷总字节数');
            if (fnv1a(pb) != fnv1a(pa)) {
              expect(pb, orderedEquals(pa), reason: '轨道 $i 的载荷字节必须逐字节一致');
            }
          }
        } finally {
          rafA.closeSync();
          rafB.closeSync();
        }

        final report = inspectFile(out, threshold: 100000);
        expect(report.health, Mp4Health.ok, reason: report.detail);
        expect(report.faststart, isTrue);
        expect(report.videoSamples, 120);
        expect(report.audioSamples, 189);
      } finally {
        if (out.existsSync()) out.deleteSync();
      }
    });
  }

  test('修复：交错极差的分片文件重排后距离显著变小', () {
    final bad = inspectFile(fixture('fragmented_bad.mp4'), threshold: 200000);
    final out = tempOut('mp4fix-frag-improve');
    try {
      repairTo(fixture('fragmented_bad.mp4'), out);
      final fixed = inspectFile(out, threshold: 200000);
      expect(fixed.health, Mp4Health.ok, reason: fixed.detail);
      expect(
        fixed.interleaveMaxBytes < bad.interleaveMaxBytes / 3,
        isTrue,
        reason: 'fixed=${fixed.interleaveMaxBytes} bad=${bad.interleaveMaxBytes}',
      );
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  });

  test('修复分片文件支持取消', () {
    final out = tempOut('mp4fix-frag-cancel');
    try {
      expect(
        () => repairTo(fixture('fragmented.mp4'), out,
            isCancelled: () => true),
        throwsA(isA<RepairCancelledException>()),
      );
    } finally {
      if (out.existsSync()) out.deleteSync();
    }
  });

  test('截断的分片文件：检测判损坏、修复失败', () {
    final src = fixture('fragmented.mp4');
    final bytes = src.readAsBytesSync();
    final cut = File('${Directory.systemTemp.path}/mp4fix-frag-cut-'
        '${DateTime.now().microsecondsSinceEpoch}.mp4');
    cut.writeAsBytesSync(bytes.sublist(0, (bytes.length * 0.6).toInt()));
    final out = tempOut('mp4fix-frag-cut-fixed');
    try {
      final report = inspectFile(cut);
      expect(report.health, Mp4Health.corrupt, reason: report.detail);
      expect(
        report.detail.contains('截断') ||
            report.detail.contains('越界') ||
            report.detail.contains('损坏'),
        isTrue,
        reason: report.detail,
      );
      expect(
        () => repairTo(cut, out),
        throwsA(isA<RepairException>()),
      );
    } finally {
      if (cut.existsSync()) cut.deleteSync();
      if (out.existsSync()) out.deleteSync();
    }
  });
}
