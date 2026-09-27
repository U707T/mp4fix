import 'dart:typed_data';

import 'binary.dart';
import 'boxes.dart';
import 'seekable_input.dart';

/// 修复统计。
class RepairStats {
  const RepairStats({
    required this.trackCount,
    required this.outputChunks,
    required this.payloadBytes,
    required this.outputBytes,
    required this.moovBytes,
    required this.usedCo64,
  });

  final int trackCount;

  /// 重排后的输出块数（含全部轨道）。
  final int outputChunks;

  /// 有效载荷（样本数据）总字节数。
  final int payloadBytes;

  /// 输出文件总字节数。
  final int outputBytes;

  /// 输出 moov 的字节数。
  final int moovBytes;

  /// 是否使用了 64 位 chunk 偏移（co64）。
  final bool usedCo64;
}

/// MP4 无损修复引擎。
///
/// 针对"音视频交错（interleave）被打乱"的 MP4 文件：
///  - 逐样本读取原始数据（不重新编码，画质无损）
///  - 按时间重新交错（每 ~0.5 秒一块、块大小有上限）
///  - moov 前置（faststart），丢弃无用的尾部/元数据垃圾
///
/// 输出为一个干净、顺序读取友好的 MP4。
class Mp4Repair {
  Mp4Repair._(
    this._input,
    this._output,
    this._chunkTargetMs,
    this._isCancelled,
    this._onProgress,
  );

  /// 默认目标块时长（毫秒）。
  static const int defaultChunkTargetMs = 500;

  static const int _maxChunkBytes = 2 * 1024 * 1024;
  static const int _maxChunkSamples = 4096;
  static const int _copyBufSize = 1 << 20;
  static const int _coalesceCap = 8 * (1 << 20);
  static const int _u32Max = 0xFFFFFFFF;

  static const int _kindRaw = 0;
  static const int _kindStsc = 1;
  static const int _kindOffsets = 2;

  final SeekableInput _input;
  final SyncSink _output;
  final int _chunkTargetMs;
  final bool Function() _isCancelled;
  final void Function(int processed, int total) _onProgress;

  Uint8List? _mvhdRaw;

  /// 执行一次修复。
  ///
  /// [onProgress] 回调为 (已处理字节, 有效载荷总字节)；[isCancelled] 返回 true 时
  /// 抛出 [RepairCancelledException]（输出可能不完整，调用方负责清理）。
  static RepairStats repair(
    SeekableInput input,
    SyncSink output, {
    int chunkTargetMs = defaultChunkTargetMs,
    bool Function()? isCancelled,
    void Function(int processed, int total)? onProgress,
  }) {
    return Mp4Repair._(
      input,
      output,
      chunkTargetMs,
      isCancelled ?? _neverCancelled,
      onProgress ?? _noProgress,
    ).run();
  }

  static bool _neverCancelled() => false;

  static void _noProgress(int processed, int total) {}

  // ---------------------------------------------------------------- run

  RepairStats run() {
    final inputSize = _input.size;
    if (inputSize < 16) throw RepairException('文件太小，不是有效的 MP4');

    // 顶层盒子：找 ftyp / moov（容忍尾部垃圾）
    final top = readBoxes(_input, 0, inputSize);
    Uint8List? ftypRaw;
    Box? moovBox;
    for (final b in top) {
      switch (b.type) {
        case 'ftyp':
          ftypRaw = readBytes(_input, b.start, b.size);
        case 'moov':
          moovBox = b;
        case 'moof':
          throw RepairException('暂不支持分片（fragmented）MP4');
      }
    }
    final moov = moovBox;
    if (moov == null) {
      throw RepairException('未找到 moov 盒（可能不是 MP4 或文件损坏）');
    }
    final ftyp = ftypRaw ?? _defaultFtyp();

    // moov 子盒
    final moovChildren = readBoxes(_input, moov.payloadStart, moov.end);
    final trackBoxes = <Box>[];
    for (final b in moovChildren) {
      switch (b.type) {
        case 'mvhd':
          _mvhdRaw = readBytes(_input, b.start, b.size);
        case 'trak':
          trackBoxes.add(b);
        case 'mvex':
          throw RepairException('暂不支持分片（fragmented）MP4');
      }
    }
    if (_mvhdRaw == null) throw RepairException('moov 缺少 mvhd');
    if (trackBoxes.isEmpty) throw RepairException('文件中没有媒体轨道');

    final tracks = <_Track>[];
    for (var i = 0; i < trackBoxes.length; i++) {
      tracks.add(_parseTrack(i, trackBoxes[i]));
    }
    if (tracks.every((t) => t.sizes.isEmpty)) {
      throw RepairException('没有可读取的媒体样本');
    }

    // 每个轨道切块
    for (final t in tracks) {
      if (t.sizes.isNotEmpty) _buildChunks(t);
    }

    // 全局按时间合并
    final order = <_ChunkRef>[];
    for (final t in tracks) {
      for (var c = 0; c < t.chunkCount.length; c++) {
        order.add(_ChunkRef(t, c, t.chunkDtsStart[c] / t.timescale));
      }
    }
    if (kMp4FixDebug) {
      for (final t in tracks) {
        debugLog(
          'track${t.index} ${t.isVideo ? 'video' : (t.isAudio ? 'audio' : '?')} '
          'ts=${t.timescale} samples=${t.sizes.length} chunks=${t.chunkFirst.length} '
          'dts[0..2]=${t.dts.take(3).toList()} '
          'chunkTime[0..4]=${t.chunkDtsStart.take(5).map((v) => v / t.timescale).toList()}',
        );
      }
    }
    order.sort((a, b) {
      var r = a.time.compareTo(b.time);
      if (r == 0) r = a.track.rank.compareTo(b.track.rank);
      if (r == 0) r = a.track.index.compareTo(b.track.index);
      return r;
    });
    if (kMp4FixDebug) {
      debugLog(
        '排序后前 16 块：${order.take(16).map((it) => '${it.track.isVideo ? 'V' : (it.track.isAudio ? 'A' : '?')}@${it.time.toStringAsFixed(2)}s').join(' ')}',
      );
    }

    var payloadBytes = 0;
    for (final t in tracks) {
      for (final b in t.chunkBytes) {
        payloadBytes += b;
      }
    }

    // 布局：先按 stco(32bit) 试算，超出 4GB 再换 co64
    var useCo64 = false;
    var moovOut = _buildMoov(tracks, useCo64: false, dummy: true);
    var mdatStart = ftyp.length + moovOut.length + 8;
    _assignOffsets(order, mdatStart);
    if (_overflowCheck(tracks, mdatStart + payloadBytes)) {
      useCo64 = true;
      moovOut = _buildMoov(tracks, useCo64: true, dummy: true);
      mdatStart = ftyp.length + moovOut.length + 8;
      _assignOffsets(order, mdatStart);
      if (_overflowCheck(tracks, mdatStart + payloadBytes)) {
        throw RepairException('输出文件超过 4 GB，暂不支持');
      }
    }
    moovOut = _buildMoov(tracks, useCo64: useCo64, dummy: false);

    if (_isCancelled()) throw RepairCancelledException();

    // 写出：ftyp + moov + mdat
    _output.write(ftyp);
    _output.write(moovOut);
    final mdatHeaderLen = _writeMdatHeader(payloadBytes);

    final copyBuf = Uint8List(_copyBufSize);
    var processed = 0;
    _onProgress(0, payloadBytes);
    for (final ref in order) {
      if (_isCancelled()) throw RepairCancelledException();
      final t = ref.track;
      final ci = ref.chunkIndex;
      var i = t.chunkFirst[ci];
      final end = i + t.chunkCount[ci];
      while (i < end) {
        // 合并输入中连续的区域，减少磁盘跳转
        var j = i + 1;
        var runLen = t.sizes[i];
        while (j < end &&
            runLen < _coalesceCap &&
            t.srcOffsets[j] == t.srcOffsets[j - 1] + t.sizes[j - 1]) {
          runLen += t.sizes[j];
          j++;
        }
        var src = t.srcOffsets[i];
        var remaining = runLen;
        while (remaining > 0) {
          final step = remaining > copyBuf.length ? copyBuf.length : remaining;
          var got = 0;
          while (got < step) {
            final n = _input.read(src + got, copyBuf, got, step - got);
            if (n <= 0) throw RepairException('数据读取失败（文件可能被截断）');
            got += n;
          }
          _output.write(copyBuf, 0, step);
          src += step;
          remaining -= step;
        }
        processed += runLen;
        i = j;
        _onProgress(processed, payloadBytes);
        if (_isCancelled()) throw RepairCancelledException();
      }
    }
    _output.flush();

    return RepairStats(
      trackCount: tracks.length,
      outputChunks: order.length,
      payloadBytes: payloadBytes,
      outputBytes: ftyp.length + moovOut.length + mdatHeaderLen + payloadBytes,
      moovBytes: moovOut.length,
      usedCo64: useCo64,
    );
  }

  bool _overflowCheck(List<_Track> tracks, int totalEnd) {
    if (totalEnd > _u32Max) return true;
    for (final t in tracks) {
      for (var i = 0; i < t.chunkCount.length; i++) {
        if (t.chunkOutOffset[i] + t.chunkBytes[i] > _u32Max) return true;
      }
    }
    return false;
  }

  void _assignOffsets(List<_ChunkRef> order, int base) {
    var pos = base;
    for (final ref in order) {
      final t = ref.track;
      t.chunkOutOffset[ref.chunkIndex] = pos;
      pos += t.chunkBytes[ref.chunkIndex];
    }
  }

  // ---------------------------------------------------------------- parse

  _Track _parseTrack(int index, Box trak) {
    final t = _Track(index);
    final trakChildren = readBoxes(_input, trak.payloadStart, trak.end);
    final mdia = _firstOf(trakChildren, 'mdia');
    if (mdia == null) throw RepairException('trak 缺少 mdia 盒');
    _splitInto(trakChildren, 'mdia', t.trakPre, t.trakPost);

    final mdiaChildren = readBoxes(_input, mdia.payloadStart, mdia.end);
    final minf = _firstOf(mdiaChildren, 'minf');
    if (minf == null) throw RepairException('mdia 缺少 minf 盒');
    _splitInto(mdiaChildren, 'minf', t.mdiaPre, t.mdiaPost);

    final mdhd = _firstOf(mdiaChildren, 'mdhd');
    if (mdhd == null) throw RepairException('mdia 缺少 mdhd 盒');
    final mdhdRaw = readBytes(_input, mdhd.start, mdhd.size);
    final mdhdVer = mdhdRaw[8];
    // v0: creation@12(32) modification@16(32) timescale@20(32)
    // v1: creation@12(64) modification@20(64) timescale@28(32)  ← timescale 仍是 32 位！
    t.timescale = mdhdVer == 1 ? u32(mdhdRaw, 28) : u32(mdhdRaw, 20);
    if (t.timescale <= 0) throw RepairException('mdhd timescale 异常');

    final hdlr = _firstOf(mdiaChildren, 'hdlr');
    if (hdlr != null) {
      final hr = readBytes(_input, hdlr.start, hdlr.size < 24 ? hdlr.size : 24);
      final handlerType = fourcc(hr, 16);
      t.isVideo = handlerType == 'vide';
      t.isAudio = handlerType == 'soun';
    }

    final minfChildren = readBoxes(_input, minf.payloadStart, minf.end);
    final stbl = _firstOf(minfChildren, 'stbl');
    if (stbl == null) throw RepairException('minf 缺少 stbl 盒');
    _splitInto(minfChildren, 'stbl', t.minfPre, t.minfPost);

    _parseStbl(t, stbl);
    return t;
  }

  Box? _firstOf(List<Box> boxes, String type) {
    for (final b in boxes) {
      if (b.type == type) return b;
    }
    return null;
  }

  void _splitInto(
    List<Box> children,
    String target,
    List<Uint8List> pre,
    List<Uint8List> post,
  ) {
    var found = false;
    for (final b in children) {
      if (!found && b.type == target) {
        found = true;
        continue;
      }
      final raw = readBytes(_input, b.start, b.size);
      if (found) {
        post.add(raw);
      } else {
        pre.add(raw);
      }
    }
  }

  void _parseStbl(_Track t, Box stbl) {
    final children = readBoxes(_input, stbl.payloadStart, stbl.end);

    List<int>? sizes;
    List<List<int>>? stscEntries;
    List<int>? chunkOffsets;
    List<int>? sttsCounts;
    List<int>? sttsDeltas;

    for (final b in children) {
      final raw = readBytes(_input, b.start, b.size);
      switch (b.type) {
        case 'stsc':
          stscEntries = _parseStsc(raw);
          t.stblParts.add(const _StblPart.stsc());
        case 'stco':
          chunkOffsets = _parseStco(raw, is64: false);
          t.stblParts.add(const _StblPart.offsets());
        case 'co64':
          chunkOffsets = _parseStco(raw, is64: true);
          t.stblParts.add(const _StblPart.offsets());
        case 'stsz':
          sizes = _parseStsz(raw);
          t.stblParts.add(_StblPart.raw(raw));
        case 'stts':
          final e = _parseStts(raw);
          sttsCounts = e.counts;
          sttsDeltas = e.deltas;
          t.stblParts.add(_StblPart.raw(raw));
        default:
          t.stblParts.add(_StblPart.raw(raw));
      }
    }
    if (sizes == null) throw RepairException('stbl 缺少 stsz 盒');
    final sz = sizes;
    final stsc = stscEntries;
    if (stsc == null) throw RepairException('stbl 缺少 stsc 盒');
    final offs = chunkOffsets;
    if (offs == null) throw RepairException('stbl 缺少 stco 盒');
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
    final dlt = List<int>.filled(n, 0);
    var idx = 0;
    var acc = 0;
    for (var k = 0; k < counts.length; k++) {
      var c = counts[k];
      final d = deltas[k];
      while (c-- > 0) {
        dlt[idx] = d;
        dts[idx] = acc;
        acc += d;
        idx++;
      }
    }

    final srcOff = List<int>.filled(n, 0);
    final desc = List<int>.filled(n, 0);
    var s = 0;
    var e = 0;
    for (var ci = 0; ci < offs.length; ci++) {
      final chunkNo = ci + 1;
      while (e + 1 < stsc.length && chunkNo >= stsc[e + 1][0]) {
        e++;
      }
      final spc = stsc[e][1];
      final d = stsc[e][2];
      var o = offs[ci];
      for (var k = 0; k < spc; k++) {
        if (s >= n) throw RepairException('stsc/stco 与实际样本数不一致');
        srcOff[s] = o;
        desc[s] = d;
        o += sz[s];
        s++;
      }
    }
    if (s != n) throw RepairException('stsc/stco 与实际样本数不一致');

    final fileSize = _input.size;
    for (var i = 0; i < n; i++) {
      if (sz[i] < 0) throw RepairException('样本大小异常');
      final end = srcOff[i] + sz[i];
      if (srcOff[i] < 0 || end > fileSize) {
        throw RepairException('样本数据越界（文件可能被截断）');
      }
    }

    t.sizes = sz;
    t.deltas = dlt;
    t.dts = dts;
    t.srcOffsets = srcOff;
    t.descIdx = desc;
  }

  List<List<int>> _parseStsc(Uint8List raw) {
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

  List<int> _parseStco(Uint8List raw, {required bool is64}) {
    final cnt = u32AsInt(raw, 12);
    final out = List<int>.filled(cnt, 0);
    var p = 16;
    for (var i = 0; i < cnt; i++) {
      out[i] = is64 ? u64(raw, p) : u32(raw, p);
      p += is64 ? 8 : 4;
    }
    return out;
  }

  List<int> _parseStsz(Uint8List raw) {
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

  ({List<int> counts, List<int> deltas}) _parseStts(Uint8List raw) {
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

  // ---------------------------------------------------------------- chunking

  void _buildChunks(_Track t) {
    final n = t.sizes.length;
    final target = t.timescale * _chunkTargetMs ~/ 1000;
    debugLog('buildChunks track${t.index} n=$n target=$target ts=${t.timescale}');
    final first = <int>[];
    final cnt = <int>[];
    final dtsS = <int>[];
    final byt = <int>[];
    final dsc = <int>[];
    var i = 0;
    while (i < n) {
      final start = i;
      var b = 0;
      while (i < n) {
        b += t.sizes[i];
        i++;
        final dur = t.dts[i - 1] + t.deltas[i - 1] - t.dts[start];
        if (dur >= target) break;
        if (b >= _maxChunkBytes) break;
        if (i - start >= _maxChunkSamples) break;
      }
      first.add(start);
      cnt.add(i - start);
      dtsS.add(t.dts[start]);
      byt.add(b);
      dsc.add(t.descIdx[start]);
    }
    t.chunkFirst = first;
    t.chunkCount = cnt;
    t.chunkDtsStart = dtsS;
    t.chunkBytes = byt;
    t.chunkDesc = dsc;
    t.chunkOutOffset = List<int>.filled(first.length, 0);
  }

  // ---------------------------------------------------------------- moov build

  Uint8List _buildMoov(
    List<_Track> tracks, {
    required bool useCo64,
    required bool dummy,
  }) {
    final parts = <Uint8List>[_mvhdRaw!];
    for (final t in tracks) {
      parts.add(_buildTrak(t, useCo64: useCo64, dummy: dummy));
    }
    return _boxBytes('moov', _concat(parts));
  }

  Uint8List _buildTrak(
    _Track t, {
    required bool useCo64,
    required bool dummy,
  }) {
    final stblChildren = <Uint8List>[];
    for (final p in t.stblParts) {
      if (p.kind == _kindStsc) {
        stblChildren.add(_buildStsc(t));
      } else if (p.kind == _kindOffsets) {
        stblChildren.add(_buildOffsetsBox(t, useCo64: useCo64, dummy: dummy));
      } else {
        stblChildren.add(p.raw!);
      }
    }
    final stbl = _boxBytes('stbl', _concat(stblChildren));
    final minf = _boxBytes(
      'minf',
      _concat([_concat(t.minfPre), stbl, _concat(t.minfPost)]),
    );
    final mdia = _boxBytes(
      'mdia',
      _concat([_concat(t.mdiaPre), minf, _concat(t.mdiaPost)]),
    );
    return _boxBytes(
      'trak',
      _concat([_concat(t.trakPre), mdia, _concat(t.trakPost)]),
    );
  }

  Uint8List _buildStsc(_Track t) {
    final entries = <List<int>>[]; // firstChunk, samplesPerChunk, descIndex
    for (var c = 0; c < t.chunkCount.length; c++) {
      final spc = t.chunkCount[c];
      final desc = t.chunkDesc[c];
      if (entries.isEmpty ||
          entries.last[1] != spc ||
          entries.last[2] != desc) {
        entries.add([c + 1, spc, desc]);
      }
    }
    final payload = Uint8List(8 + entries.length * 12);
    putU32(payload, 0, 0);
    putU32(payload, 4, entries.length);
    var o = 8;
    for (final e in entries) {
      putU32(payload, o, e[0]);
      putU32(payload, o + 4, e[1]);
      putU32(payload, o + 8, e[2]);
      o += 12;
    }
    return _boxBytes('stsc', payload);
  }

  Uint8List _buildOffsetsBox(
    _Track t, {
    required bool useCo64,
    required bool dummy,
  }) {
    final n = t.chunkCount.length;
    if (!useCo64) {
      final payload = Uint8List(8 + 4 * n);
      putU32(payload, 0, 0);
      putU32(payload, 4, n);
      for (var i = 0; i < n; i++) {
        putU32(payload, 8 + 4 * i, dummy ? 0 : t.chunkOutOffset[i]);
      }
      return _boxBytes('stco', payload);
    }
    final payload = Uint8List(8 + 8 * n);
    putU32(payload, 0, 0);
    putU32(payload, 4, n);
    for (var i = 0; i < n; i++) {
      putU64(payload, 8 + 8 * i, dummy ? 0 : t.chunkOutOffset[i]);
    }
    return _boxBytes('co64', payload);
  }

  Uint8List _boxBytes(String type, Uint8List payload) {
    final out = Uint8List(8 + payload.length);
    putU32(out, 0, out.length);
    out.setRange(4, 8, asciiBytes(type));
    out.setRange(8, out.length, payload);
    return out;
  }

  Uint8List _concat(List<Uint8List> parts) {
    var n = 0;
    for (final p in parts) {
      n += p.length;
    }
    final out = Uint8List(n);
    var o = 0;
    for (final p in parts) {
      out.setRange(o, o + p.length, p);
      o += p.length;
    }
    return out;
  }

  int _writeMdatHeader(int payloadBytes) {
    if (payloadBytes + 8 <= _u32Max) {
      final hdr = Uint8List(8);
      putU32(hdr, 0, payloadBytes + 8);
      hdr.setRange(4, 8, asciiBytes('mdat'));
      _output.write(hdr);
      return 8;
    }
    final hdr = Uint8List(16);
    putU32(hdr, 0, 1);
    hdr.setRange(4, 8, asciiBytes('mdat'));
    putU64(hdr, 8, payloadBytes + 16);
    _output.write(hdr);
    return 16;
  }

  Uint8List _defaultFtyp() {
    final compat = asciiBytes('isomiso2avc1mp41');
    final out = Uint8List(8 + 4 + 4 + compat.length);
    putU32(out, 0, out.length);
    out.setRange(4, 8, asciiBytes('ftyp'));
    putU32(out, 8, 512);
    out.setRange(12, 16, asciiBytes('isom'));
    out.setRange(16, 16 + compat.length, compat);
    return out;
  }
}

class _ChunkRef {
  const _ChunkRef(this.track, this.chunkIndex, this.time);

  final _Track track;
  final int chunkIndex;
  final double time;
}

class _StblPart {
  const _StblPart.raw(this.raw) : kind = Mp4Repair._kindRaw;
  const _StblPart.stsc()
      : kind = Mp4Repair._kindStsc,
        raw = null;
  const _StblPart.offsets()
      : kind = Mp4Repair._kindOffsets,
        raw = null;

  final int kind;
  final Uint8List? raw;
}

class _Track {
  _Track(this.index);

  final int index;
  int timescale = 0;
  bool isVideo = false;
  bool isAudio = false;

  int get rank => isVideo ? 0 : (isAudio ? 1 : 2);

  List<int> sizes = const [];
  List<int> deltas = const [];
  List<int> dts = const [];
  List<int> srcOffsets = const [];
  List<int> descIdx = const [];

  final List<Uint8List> trakPre = [];
  final List<Uint8List> trakPost = [];
  final List<Uint8List> mdiaPre = [];
  final List<Uint8List> mdiaPost = [];
  final List<Uint8List> minfPre = [];
  final List<Uint8List> minfPost = [];
  final List<_StblPart> stblParts = [];

  List<int> chunkFirst = const [];
  List<int> chunkCount = const [];
  List<int> chunkDtsStart = const [];
  List<int> chunkBytes = const [];
  List<int> chunkDesc = const [];
  List<int> chunkOutOffset = const [];
}
