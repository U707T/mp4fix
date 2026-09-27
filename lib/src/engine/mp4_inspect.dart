import 'dart:typed_data';

import 'binary.dart';
import 'boxes.dart';
import 'seekable_input.dart';

/// MP4 健康状态。
enum Mp4Health {
  /// 健康：交错正常且 moov 前置。
  ok,

  /// 交错被打乱：可用无损重排修复（不影响画质）。
  needsReinterleave,

  /// 仅未 moov 前置：可正常播放，串流体验可优化（修复会顺带前置 moov）。
  optimizable,

  /// 分片（fragmented）MP4 或非 MP4 文件：本工具暂不支持。
  unsupported,

  /// 结构损坏 / 截断：无法无损修复。
  corrupt,
}

/// 单个文件的检测报告。
class InspectReport {
  const InspectReport({
    required this.health,
    required this.detail,
    required this.fileSize,
    required this.trackCount,
    required this.videoSamples,
    required this.audioSamples,
    required this.interleaveMaxBytes,
    required this.interleaveMeanBytes,
    required this.faststart,
  });

  final Mp4Health health;

  /// 人类可读说明（损坏原因 / 交错指标等）。
  final String detail;
  final int fileSize;
  final int trackCount;
  final int videoSamples;
  final int audioSamples;

  /// 同刻音视频样本距离的最大值（字节）。
  final int interleaveMaxBytes;

  /// 同刻音视频样本距离的平均值（字节）。
  final int interleaveMeanBytes;

  /// moov 是否已前置（faststart）。
  final bool faststart;

  @override
  String toString() => 'InspectReport(${health.name}: $detail)';
}

/// MP4 健康检测（供批量扫描 / WebDAV 扫描使用）。
///
/// 只读取文件头部与 moov 盒（经由 [SeekableInput] 随机读取），无需完整下载：
///  - 结构完整性：能否定位 moov、样本表是否自洽、样本是否越界（截断）、ctts 表是否可疑；
///  - 交错质量：同刻音视频数据在文件中的距离（距离过大 = 弱读取设备 / 流式播放易卡顿，
///    可用无损重排修复）；
///  - 其他：是否 moov 前置（faststart）、是否分片（fragmented）MP4。
abstract final class Mp4Inspect {
  /// 交错距离默认阈值：≥ 4MB 视为需要重排。
  static const int defaultInterleaveThreshold = 4 * 1024 * 1024;

  /// 交错采样的最大视频样本数（超大文件按步长抽样，控制耗时）。
  static const int _maxSampledVideoSamples = 400000;

  static InspectReport inspect(
    SeekableInput input, {
    int interleaveThresholdBytes = defaultInterleaveThreshold,
  }) {
    final fileSize = input.size;
    if (fileSize < 16) {
      return _corrupt(fileSize, '文件太小，不是有效的 MP4');
    }

    // ------------------------------------------------------------ 顶层盒子
    final List<Box> top;
    final Box? moov;
    final Box? mdat;
    final Box? ftyp;
    try {
      top = readBoxes(input, 0, fileSize);
      moov = _firstOf(top, 'moov');
      mdat = _firstOf(top, 'mdat');
      ftyp = _firstOf(top, 'ftyp');
    } catch (e) {
      return _corrupt(fileSize, '读取文件头部失败：${errorMessage(e)}');
    }
    if (top.any((b) => b.type == 'moof')) {
      return _unsupported(fileSize, '分片（fragmented）MP4 暂不支持');
    }
    if (ftyp == null) {
      return _corrupt(fileSize, '未找到 ftyp 盒（非 MP4 文件？）');
    }
    if (moov == null) {
      return _corrupt(fileSize, '未找到 moov 盒（文件损坏或非 MP4）');
    }

    // ------------------------------------------------------------ 轨道
    final tracks = <_TrackInfo>[];
    try {
      final moovChildren = readBoxes(input, moov.payloadStart, moov.end);
      if (moovChildren.any((b) => b.type == 'mvex')) {
        return _unsupported(fileSize, '分片（fragmented）MP4 暂不支持');
      }
      var index = 0;
      for (final b in moovChildren) {
        if (b.type == 'trak') {
          tracks.add(_parseTrack(input, index++, b, fileSize));
        }
      }
    } catch (e) {
      return _corrupt(fileSize, '结构损坏：${errorMessage(e)}');
    }
    if (tracks.isEmpty) {
      return _corrupt(fileSize, '文件中没有媒体轨道');
    }
    _TrackInfo? video;
    _TrackInfo? audio;
    for (final t in tracks) {
      if (video == null && t.isVideo && t.samples > 0) video = t;
      if (audio == null && t.isAudio && t.samples > 0) audio = t;
    }
    if (video == null && audio == null) {
      return _corrupt(fileSize, '没有可读取的媒体样本');
    }

    // ------------------------------------------------------------ 交错距离
    var maxDist = 0;
    var meanDist = 0;
    if (video != null && audio != null) {
      final d = _interleaveDistance(video, audio);
      maxDist = d.max;
      meanDist = d.mean;
    }

    final faststart = mdat == null || moov.start < mdat.start;
    final note = StringBuffer();
    if (video != null && audio != null) {
      note.write('同刻音视频距离：最大 ${formatBytes(maxDist)}、平均 ${formatBytes(meanDist)}');
    } else {
      note.write('单轨文件');
    }
    if (!faststart) note.write('；moov 未前置（faststart）');

    final Mp4Health health;
    if (video != null && audio != null && maxDist >= interleaveThresholdBytes) {
      health = Mp4Health.needsReinterleave;
    } else if (!faststart) {
      health = Mp4Health.optimizable;
    } else {
      health = Mp4Health.ok;
    }

    final String detail;
    switch (health) {
      case Mp4Health.needsReinterleave:
        detail = '$note（判定阈值 ${formatBytes(interleaveThresholdBytes)}：'
            '最大距离超过它即视为交错不良；弱读取设备 / 流式播放易卡顿，可无损重排修复）';
      case Mp4Health.optimizable:
        detail = '$note（可修复以优化串流体验）';
      default:
        detail = note.toString();
    }

    return InspectReport(
      health: health,
      detail: detail,
      fileSize: fileSize,
      trackCount: tracks.length,
      videoSamples: video?.samples ?? 0,
      audioSamples: audio?.samples ?? 0,
      interleaveMaxBytes: maxDist,
      interleaveMeanBytes: meanDist,
      faststart: faststart,
    );
  }

  static InspectReport _corrupt(int size, String message) => InspectReport(
        health: Mp4Health.corrupt,
        detail: message,
        fileSize: size,
        trackCount: 0,
        videoSamples: 0,
        audioSamples: 0,
        interleaveMaxBytes: 0,
        interleaveMeanBytes: 0,
        faststart: false,
      );

  static InspectReport _unsupported(int size, String message) => InspectReport(
        health: Mp4Health.unsupported,
        detail: message,
        fileSize: size,
        trackCount: 0,
        videoSamples: 0,
        audioSamples: 0,
        interleaveMaxBytes: 0,
        interleaveMeanBytes: 0,
        faststart: false,
      );

  // ---------------------------------------------------------------- 交错距离

  static ({int max, int mean}) _interleaveDistance(
    _TrackInfo video,
    _TrackInfo audio,
  ) {
    final vDts = video.dts!;
    final vOff = video.offsets!;
    final aDts = audio.dts!;
    final aOff = audio.offsets!;
    final vn = vDts.length;
    final an = aDts.length;
    final step = vn > _maxSampledVideoSamples ? vn ~/ _maxSampledVideoSamples : 1;

    // 音频样本按时间有序（stts 即时间序），构造时间数组用于二分查找
    final aTimes = Float64List(an);
    for (var i = 0; i < an; i++) {
      aTimes[i] = aDts[i] / audio.timescale;
    }

    var count = 0;
    var max = 0;
    var sum = 0.0;
    var vi = 0;
    while (vi < vn) {
      final t = vDts[vi] / video.timescale;
      final j = _lowerBound(aTimes, t);
      var best = -1;
      var k = j - 1;
      if (k >= 0 && k < an) best = (vOff[vi] - aOff[k]).abs();
      k = j;
      if (k >= 0 && k < an) {
        final d = (vOff[vi] - aOff[k]).abs();
        if (best < 0 || d < best) best = d;
      }
      if (best >= 0) {
        if (best > max) max = best;
        sum += best;
        count++;
      }
      vi += step;
    }
    final mean = count == 0 ? 0 : (sum / count).toInt();
    return (max: max, mean: mean);
  }

  static int _lowerBound(Float64List a, double v) {
    var lo = 0;
    var hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (a[mid] < v) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  // ---------------------------------------------------------------- 解析

  static Box? _firstOf(List<Box> boxes, String type) {
    for (final b in boxes) {
      if (b.type == type) return b;
    }
    return null;
  }

  static _TrackInfo _parseTrack(
    SeekableInput input,
    int index,
    Box trak,
    int fileSize,
  ) {
    final t = _TrackInfo(index);
    final trakChildren = readBoxes(input, trak.payloadStart, trak.end);
    final mdia = _firstOf(trakChildren, 'mdia');
    if (mdia == null) throw RepairException('trak 缺少 mdia 盒');
    final mdiaChildren = readBoxes(input, mdia.payloadStart, mdia.end);
    final minf = _firstOf(mdiaChildren, 'minf');
    if (minf == null) throw RepairException('mdia 缺少 minf 盒');

    final mdhd = _firstOf(mdiaChildren, 'mdhd');
    if (mdhd == null) throw RepairException('mdia 缺少 mdhd 盒');
    final mdhdRaw = readBytes(input, mdhd.start, mdhd.size);
    final mdhdVer = mdhdRaw[8];
    // v0: timescale@20(32)；v1: creation/modification 各 64 位，timescale@28 仍是 32 位
    t.timescale = mdhdVer == 1 ? u32(mdhdRaw, 28) : u32(mdhdRaw, 20);
    if (t.timescale <= 0) throw RepairException('mdhd timescale 异常');

    final hdlr = _firstOf(mdiaChildren, 'hdlr');
    if (hdlr != null) {
      final hr = readBytes(input, hdlr.start, hdlr.size < 24 ? hdlr.size : 24);
      final handler = fourcc(hr, 16);
      t.isVideo = handler == 'vide';
      t.isAudio = handler == 'soun';
    }

    final minfChildren = readBoxes(input, minf.payloadStart, minf.end);
    final stbl = _firstOf(minfChildren, 'stbl');
    if (stbl == null) throw RepairException('minf 缺少 stbl 盒');

    _parseStbl(input, t, stbl, fileSize);
    return t;
  }

  static void _parseStbl(
    SeekableInput input,
    _TrackInfo t,
    Box stbl,
    int fileSize,
  ) {
    final children = readBoxes(input, stbl.payloadStart, stbl.end);

    List<int>? sizes;
    List<List<int>>? stsc;
    List<int>? offsets;
    List<int>? sttsCounts;
    List<int>? sttsDeltas;

    for (final b in children) {
      final raw = readBytes(input, b.start, b.size);
      switch (b.type) {
        case 'stsc':
          stsc = _parseStsc(raw);
        case 'stco':
          offsets = _parseStco(raw, is64: false);
        case 'co64':
          offsets = _parseStco(raw, is64: true);
        case 'stsz':
          sizes = _parseStsz(raw);
        case 'stts':
          final e = _parseStts(raw);
          sttsCounts = e.counts;
          sttsDeltas = e.deltas;
        case 'ctts':
          _validateCtts(raw);
      }
    }

    final sz = sizes;
    if (sz == null) throw RepairException('stbl 缺少 stsz 盒');
    final stscE = stsc;
    if (stscE == null) throw RepairException('stbl 缺少 stsc 盒');
    final offs = offsets;
    if (offs == null) throw RepairException('stbl 缺少 stco/co64 盒');
    final counts = sttsCounts;
    if (counts == null) throw RepairException('stbl 缺少 stts 盒');
    final deltas = sttsDeltas!;

    final n = sz.length;
    var total = 0;
    for (final c in counts) {
      total += c;
    }
    if (total != n) throw RepairException('stts 与 stsz 样本数不一致');

    final dts = List<int>.filled(n, 0);
    var idx = 0;
    var acc = 0;
    for (var k = 0; k < counts.length; k++) {
      var c = counts[k];
      final d = deltas[k];
      while (c-- > 0) {
        dts[idx] = acc;
        acc += d;
        idx++;
      }
    }

    final srcOff = List<int>.filled(n, 0);
    var s = 0;
    var e = 0;
    for (var ci = 0; ci < offs.length; ci++) {
      final chunkNo = ci + 1;
      while (e + 1 < stscE.length && chunkNo >= stscE[e + 1][0]) {
        e++;
      }
      final spc = stscE[e][1];
      var o = offs[ci];
      for (var k = 0; k < spc; k++) {
        if (s >= n) throw RepairException('stsc/stco 与实际样本数不一致');
        srcOff[s] = o;
        o += sz[s];
        s++;
      }
    }
    if (s != n) throw RepairException('stsc/stco 与实际样本数不一致');

    for (var i = 0; i < n; i++) {
      if (sz[i] < 0) throw RepairException('样本大小异常');
      final end = srcOff[i] + sz[i];
      if (srcOff[i] < 0 || end > fileSize) {
        throw RepairException('样本数据越界（文件可能被截断）');
      }
    }

    t.samples = n;
    t.dts = dts;
    t.offsets = srcOff;
  }

  /// ctts 结构硬检查：盒长与条目数自洽性（检测"corrupted CTTS"一类问题的前半段）。
  /// 结构上不可能成立的 ctts 直接判为损坏；通过的 ctts 不做值层面校验。
  static void _validateCtts(Uint8List raw) {
    if (raw.length < 16) throw RepairException('ctts 盒过小（疑似损坏）');
    final cnt = u32(raw, 12);
    if (cnt == 0) throw RepairException('ctts 表为空（疑似损坏）');
    final need = 16 + cnt * 8;
    if (need > raw.length) throw RepairException('ctts 表长度异常（疑似损坏）');
  }

  // ---------------------------------------------------------------- 表解析

  static List<List<int>> _parseStsc(Uint8List raw) {
    final cnt = u32AsInt(raw, 12);
    if (cnt <= 0) throw RepairException('stsc 表为空');
    final out = List<List<int>>.generate(cnt, (_) => List<int>.filled(3, 0));
    var p = 16;
    for (var i = 0; i < cnt; i++) {
      out[i][0] = u32(raw, p);
      out[i][1] = u32(raw, p + 4);
      out[i][2] = u32(raw, p + 8);
      p += 12;
    }
    for (var i = 1; i < cnt; i++) {
      if (out[i][0] <= out[i - 1][0]) throw RepairException('stsc 表异常');
    }
    return out;
  }

  static List<int> _parseStco(Uint8List raw, {required bool is64}) {
    final cnt = u32AsInt(raw, 12);
    final out = List<int>.filled(cnt, 0);
    var p = 16;
    for (var i = 0; i < cnt; i++) {
      out[i] = is64 ? u64(raw, p) : u32(raw, p);
      p += is64 ? 8 : 4;
    }
    return out;
  }

  static List<int> _parseStsz(Uint8List raw) {
    final uniform = u32(raw, 12);
    final cnt = u32AsInt(raw, 16);
    final out = List<int>.filled(cnt, 0);
    if (uniform != 0) {
      out.fillRange(0, cnt, uniform);
    } else {
      var p = 20;
      for (var i = 0; i < cnt; i++) {
        out[i] = u32(raw, p);
        p += 4;
      }
    }
    return out;
  }

  static ({List<int> counts, List<int> deltas}) _parseStts(Uint8List raw) {
    final cnt = u32AsInt(raw, 12);
    final counts = List<int>.filled(cnt, 0);
    final deltas = List<int>.filled(cnt, 0);
    var p = 16;
    for (var i = 0; i < cnt; i++) {
      counts[i] = u32(raw, p);
      deltas[i] = u32(raw, p + 4);
      p += 8;
    }
    return (counts: counts, deltas: deltas);
  }
}

class _TrackInfo {
  _TrackInfo(this.index);

  final int index;
  int timescale = 0;
  bool isVideo = false;
  bool isAudio = false;
  int samples = 0;
  List<int>? dts;
  List<int>? offsets;
}
