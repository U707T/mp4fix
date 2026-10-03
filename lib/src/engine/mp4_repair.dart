import 'dart:typed_data';

import 'binary.dart';
import 'boxes.dart';
import 'mp4_fragments.dart';
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
/// 分片（fragmented）MP4（含 moof/mvex）会先解析 moof/traf/trun 汇总样本，
/// 再按同样流程无损转换为标准 MP4（去掉分片结构；必要时补全时长 / 用 elst
/// 保留轨道间起点差）。
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

  /// 输出体积上限（32 位偏移不够时改用 co64；这里只做一个理智值兜底）。
  static const int _maxOutputBytes = 1 << 40; // 1 TB

  static const int _kindRaw = 0;
  static const int _kindStsc = 1;
  static const int _kindOffsets = 2;
  static const int _kindStts = 3;
  static const int _kindStsz = 4;
  static const int _kindStss = 5;
  static const int _kindCtts = 6;

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

    // 顶层盒子：找 ftyp / moov / moof（容忍尾部垃圾）
    final top = readBoxes(_input, 0, inputSize);
    Uint8List? ftypRaw;
    Box? moovBox;
    final moofs = <Box>[];
    for (final b in top) {
      switch (b.type) {
        case 'ftyp':
          ftypRaw = readBytes(_input, b.start, b.size);
        case 'moov':
          moovBox = b;
        case 'moof':
          moofs.add(b);
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
    var hasMvex = false;
    for (final b in moovChildren) {
      switch (b.type) {
        case 'mvhd':
          _mvhdRaw = readBytes(_input, b.start, b.size);
        case 'trak':
          trackBoxes.add(b);
        case 'mvex':
          hasMvex = true;
      }
    }
    if (_mvhdRaw == null) throw RepairException('moov 缺少 mvhd');
    if (trackBoxes.isEmpty) throw RepairException('文件中没有媒体轨道');

    final List<_Track> tracks;
    if (moofs.isNotEmpty || hasMvex) {
      // 分片（fragmented）MP4：解析 moof 得到样本表，无损“扁平化”为标准 MP4
      tracks = _parseFragmentedTracks(moovChildren, trackBoxes, moofs);
    } else {
      tracks = <_Track>[];
      for (var i = 0; i < trackBoxes.length; i++) {
        tracks.add(_parseTrack(i, trackBoxes[i]));
      }
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

    // 布局：先按 stco(32bit) 试算；放不下就换 co64(64bit)，同时 mdat 用 16 字节大头部
    var useCo64 = false;
    var moovOut = _buildMoov(tracks, useCo64: false, dummy: true);
    var mdatStart = ftyp.length + moovOut.length + 8;
    _assignOffsets(order, mdatStart);
    if (_needsCo64(mdatStart + payloadBytes)) {
      useCo64 = true;
      moovOut = _buildMoov(tracks, useCo64: true, dummy: true);
      mdatStart = ftyp.length + moovOut.length + 16;
      _assignOffsets(order, mdatStart);
      if (mdatStart + payloadBytes > _maxOutputBytes) {
        throw RepairException(
          '输出文件过大（超过 ${formatBytes(_maxOutputBytes)}），暂不支持',
        );
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

  /// 32 位 chunk 偏移是否放得下（放不下就得用 co64）。
  /// 各 chunk 的偏移都落在 `[mdatStart, totalEnd]` 区间内，因此只需比较总末端。
  bool _needsCo64(int totalEnd) => totalEnd > _u32Max;

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
    if (mdhdRaw.length < 32) throw RepairException('mdhd 盒过小（疑似损坏）');
    final mdhdVer = mdhdRaw[8];
    // v0: creation@12(32) modification@16(32) timescale@20(32)
    // v1: creation@12(64) modification@20(64) timescale@28(32)  ← timescale 仍是 32 位！
    t.timescale = mdhdVer == 1 ? u32(mdhdRaw, 28) : u32(mdhdRaw, 20);
    if (t.timescale <= 0) throw RepairException('mdhd timescale 异常');

    final hdlr = _firstOf(mdiaChildren, 'hdlr');
    if (hdlr != null) {
      final hr = readBytes(_input, hdlr.start, hdlr.size < 24 ? hdlr.size : 24);
      if (hr.length < 20) throw RepairException('hdlr 盒过小（疑似损坏）');
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

  // ---------------------------------------------------------------- 分片 MP4

  /// 解析分片（fragmented）MP4：moov 提供轨道/编解码信息（采样表通常为空），
  /// 样本全部来自 moof/traf/trun；组装成与普通 stbl 等价的样本表后，
  /// 走与普通文件完全相同的「按时间切块重排」流水线（即“扁平化”转换）。
  List<_Track> _parseFragmentedTracks(
    List<Box> moovChildren,
    List<Box> trackBoxes,
    List<Box> moofs,
  ) {
    final trex = parseTrexDefaults(_input, moovChildren);

    final tracks = <_Track>[];
    final byId = <int, _Track>{};
    for (var i = 0; i < trackBoxes.length; i++) {
      final t = _parseTrackForFlatten(i, trackBoxes[i]);
      tracks.add(t);
      final id = t.trackId;
      if (id != null && !byId.containsKey(id)) byId[id] = t;
    }
    if (byId.isEmpty) {
      throw RepairException('分片 MP4 缺少 tkhd（无法关联轨道与 moof）');
    }

    final fragTracks = <int, FragmentTrackSamples>{};
    for (final id in byId.keys) {
      fragTracks[id] = FragmentTrackSamples(id);
    }
    readFragmentSamples(_input, moofs, fragTracks, defaults: trex);

    final mvhdTs = _boxTimescale(_mvhdRaw!);

    for (final t in tracks) {
      final frag = t.trackId == null ? null : fragTracks[t.trackId];
      _mergeFragments(t, frag, mvhdTs);
    }

    if (mvhdTs > 0) {
      // 各轨道 tfdt 起点不一致时，用空编辑（elst）保留相对延迟
      var baseline = -1;
      for (final t in tracks) {
        if (t.sizes.isEmpty || t.timescale <= 0) continue;
        final delay = t.firstDtsAbs * mvhdTs ~/ t.timescale;
        if (baseline < 0 || delay < baseline) baseline = delay;
      }
      if (baseline >= 0) {
        for (final t in tracks) {
          if (t.sizes.isEmpty || t.timescale <= 0) continue;
          final delay = t.firstDtsAbs * mvhdTs ~/ t.timescale;
          if (delay > baseline) t.movieDelayTicks = delay - baseline;
        }
      }
    }

    // mvhd 时长补全（分片文件的 mvhd duration 常常为 0 / 占位）
    var movieDur = 0;
    for (final t in tracks) {
      if (t.movieDuration > movieDur) movieDur = t.movieDuration;
    }
    if (movieDur > 0) {
      _mvhdRaw = _patchDuration(
        _mvhdRaw!,
        movieDur,
        v0Offset: 24,
        v1Offset: 32,
      );
    }
    return tracks;
  }

  /// 把分片样本合并进轨道（普通样本在前、分片样本接后），归一化时间戳，
  /// 并整理同步样本（stss）/ 合成偏移（ctts）/ 时长信息。
  void _mergeFragments(_Track t, FragmentTrackSamples? frag, int mvhdTs) {
    final classicCount = t.sizes.length;
    final List<int> sizes;
    final List<int> deltas;
    final List<int> srcOffsets;
    final List<int> descIdx;
    final List<int> rawDts;
    final List<int> cto;

    if (frag == null || frag.count == 0) {
      sizes = t.sizes;
      deltas = t.deltas;
      srcOffsets = t.srcOffsets;
      descIdx = t.descIdx;
      rawDts = t.dts;
      cto = t.classicCto ?? List<int>.filled(classicCount, 0, growable: true);
    } else {
      sizes = List<int>.of(t.sizes)..addAll(frag.sizes);
      deltas = List<int>.of(t.deltas)..addAll(frag.durations);
      srcOffsets = List<int>.of(t.srcOffsets)..addAll(frag.offsets);
      descIdx = List<int>.of(t.descIdx)..addAll(frag.descIdx);
      rawDts = List<int>.of(t.dts)..addAll(frag.dts);
      cto = (t.classicCto ?? List<int>.filled(classicCount, 0, growable: true))
        ..addAll(frag.compOffsets);
    }

    // 解码时间归一化：整体平移到 0 起（普通 stts 没有“起始偏移”概念，
    // 轨道间差异由 elst 空编辑表达）。
    final base = rawDts.isEmpty ? 0 : rawDts.first;
    final dts = base == 0
        ? rawDts
        : <int>[for (final v in rawDts) v - base];

    // 同步样本表（stss）：只有存在非同步样本（或普通部分带 stss）才需要
    final fragNeedStss = frag != null && frag.anyNonSync;
    final needStss = fragNeedStss || t.hasOrigStss;
    if (needStss) {
      final entries = <int>[];
      if (t.hasOrigStss) {
        entries.addAll(t.origStss);
      } else if (classicCount > 0) {
        for (var i = 1; i <= classicCount; i++) {
          entries.add(i);
        }
      }
      if (frag != null) {
        for (var i = 0; i < frag.count; i++) {
          if (frag.sync[i]) entries.add(classicCount + i + 1);
        }
      }
      t.stssEntries = entries;
    }
    t.needStss = needStss;

    t.sizes = sizes;
    t.deltas = deltas;
    t.srcOffsets = srcOffsets;
    t.descIdx = descIdx;
    t.dts = dts;
    t.cto = cto;
    t.hasCto = cto.any((v) => v != 0);
    if (t.hasCto) t.stblParts.add(const _StblPart.ctts());
    if (t.needStss) t.stblParts.add(const _StblPart.stss());

    t.firstDtsAbs = base;
    t.finalDuration = dts.isEmpty ? 0 : dts.last + deltas.last;
    if (mvhdTs > 0 && t.timescale > 0) {
      t.movieDuration = t.finalDuration * mvhdTs ~/ t.timescale;
    }
  }

  /// 解析分片 MP4 的单个 trak：采样表位置留出「生成器」占位（stts/stsc/
  /// stsz/stco 由修复时重建），stsd 等其余子盒原样保留；
  /// 若 moov 里本身就有普通样本（少见的混合文件），一并读入。
  _Track _parseTrackForFlatten(int index, Box trak) {
    final t = _Track(index);
    final trakChildren = readBoxes(_input, trak.payloadStart, trak.end);
    _splitInto(trakChildren, 'mdia', t.trakPre, t.trakPost);

    // tkhd → track_ID（分片按 track_ID 关联）
    final tkhd = _firstOf(trakChildren, 'tkhd');
    if (tkhd != null) {
      final tr = readBytes(_input, tkhd.start, tkhd.size < 32 ? tkhd.size : 32);
      if (tr.length >= 24) {
        // v0: track_ID@20(32)；v1: creation/modification 各 64 位，track_ID@28
        t.trackId = tr[8] == 1
            ? (tr.length >= 32 ? u32(tr, 28) : null)
            : u32(tr, 20);
      }
    }

    final mdia = _firstOf(trakChildren, 'mdia');
    if (mdia == null) throw RepairException('trak 缺少 mdia 盒');
    final mdiaChildren = readBoxes(_input, mdia.payloadStart, mdia.end);
    final minf = _firstOf(mdiaChildren, 'minf');
    if (minf == null) throw RepairException('mdia 缺少 minf 盒');
    _splitInto(mdiaChildren, 'minf', t.mdiaPre, t.mdiaPost);

    final mdhd = _firstOf(mdiaChildren, 'mdhd');
    if (mdhd == null) throw RepairException('mdia 缺少 mdhd 盒');
    final mdhdRaw = readBytes(_input, mdhd.start, mdhd.size);
    if (mdhdRaw.length < 32) throw RepairException('mdhd 盒过小（疑似损坏）');
    t.timescale = _boxTimescale(mdhdRaw);
    if (t.timescale <= 0) throw RepairException('mdhd timescale 异常');

    final hdlr = _firstOf(mdiaChildren, 'hdlr');
    if (hdlr != null) {
      final hr = readBytes(_input, hdlr.start, hdlr.size < 24 ? hdlr.size : 24);
      if (hr.length < 20) throw RepairException('hdlr 盒过小（疑似损坏）');
      final handlerType = fourcc(hr, 16);
      t.isVideo = handlerType == 'vide';
      t.isAudio = handlerType == 'soun';
    }

    final minfChildren = readBoxes(_input, minf.payloadStart, minf.end);
    final stbl = _firstOf(minfChildren, 'stbl');
    if (stbl == null) throw RepairException('minf 缺少 stbl 盒');
    _splitInto(minfChildren, 'stbl', t.minfPre, t.minfPost);

    // stbl 子盒：采样表换成生成器；stsd / 其他盒子原样保留
    var hasStts = false;
    var hasStsc = false;
    var hasStsz = false;
    var hasOffsets = false;
    final stblChildren = readBoxes(_input, stbl.payloadStart, stbl.end);
    for (final c in stblChildren) {
      switch (c.type) {
        case 'stsd':
          t.stblParts.add(_StblPart.raw(readBytes(_input, c.start, c.size)));
        case 'stts':
          hasStts = true;
          t.stblParts.add(const _StblPart.stts());
        case 'stsc':
          hasStsc = true;
          t.stblParts.add(const _StblPart.stsc());
        case 'stsz':
          hasStsz = true;
          t.stblParts.add(const _StblPart.stsz());
        case 'stco' || 'co64':
          hasOffsets = true;
          t.stblParts.add(const _StblPart.offsets());
        case 'stss':
          final entries = _parseStssEntries(readBytes(_input, c.start, c.size));
          if (entries.isNotEmpty) {
            t.hasOrigStss = true;
            t.origStss = entries;
          }
        case 'ctts':
          t.classicCto = _parseCttsValues(
            readBytes(_input, c.start, c.size),
            _classicSampleCountOf(stblChildren),
          );
        case 'sdtp' || 'stz2':
          break; // 参考意义已并入样本解析 / 由生成器替换
        default:
          t.stblParts.add(_StblPart.raw(readBytes(_input, c.start, c.size)));
      }
    }
    if (!hasStts) t.stblParts.add(const _StblPart.stts());
    if (!hasStsc) t.stblParts.add(const _StblPart.stsc());
    if (!hasStsz) t.stblParts.add(const _StblPart.stsz());
    if (!hasOffsets) t.stblParts.add(const _StblPart.offsets());

    // 普通样本（仅混合文件才有；empty_moov 的空表视为没有）
    final stszBox = _firstOf(stblChildren, 'stsz');
    var emptyTables = stszBox == null;
    if (!emptyTables) {
      final szRaw = readBytes(_input, stszBox.start, stszBox.size);
      emptyTables = szRaw.length < 20 || u32(szRaw, 16) == 0;
    }
    if (!emptyTables) {
      _parseStbl(t, stbl, recordParts: false);
    }
    return t;
  }

  /// stbl 里 stsz 声明的普通样本数（没有则 0）。
  int _classicSampleCountOf(List<Box> stblChildren) {
    final stsz = _firstOf(stblChildren, 'stsz');
    if (stsz == null) return 0;
    final raw = readBytes(_input, stsz.start, stsz.size);
    return raw.length < 20 ? 0 : u32(raw, 16);
  }

  /// 解析 stss（同步样本表）为 1 起的样本号列表。
  List<int> _parseStssEntries(Uint8List raw) {
    if (raw.length < 16) return const [];
    final cnt = u32AsInt(raw, 12);
    if (cnt == 0) return const [];
    checkTableFits(raw, cnt, 4, 16, 'stss');
    final out = List<int>.filled(cnt, 0);
    var p = 16;
    for (var i = 0; i < cnt; i++) {
      out[i] = u32(raw, p);
      p += 4;
    }
    return out;
  }

  /// 把 ctts 展开成逐样本的合成偏移（用于混合文件；纯分片文件用 trun 的 cto）。
  List<int> _parseCttsValues(Uint8List raw, int sampleCount) {
    if (sampleCount <= 0) return const [];
    final out = List<int>.filled(sampleCount, 0);
    if (raw.length < 16) return out;
    final ver = raw[8];
    final cnt = u32AsInt(raw, 12);
    checkTableFits(raw, cnt, 8, 16, 'ctts');
    var p = 16;
    var s = 0;
    for (var i = 0; i < cnt; i++) {
      final n = u32AsInt(raw, p);
      final v = ver == 1 ? _s32Int(raw, p + 4) : u32(raw, p + 4);
      for (var k = 0; k < n && s < sampleCount; k++) {
        out[s++] = v;
      }
      p += 8;
    }
    return out;
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

  void _parseStbl(_Track t, Box stbl, {bool recordParts = true}) {
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
          if (recordParts) t.stblParts.add(const _StblPart.stsc());
        case 'stco':
          chunkOffsets = _parseStco(raw, is64: false);
          if (recordParts) t.stblParts.add(const _StblPart.offsets());
        case 'co64':
          chunkOffsets = _parseStco(raw, is64: true);
          if (recordParts) t.stblParts.add(const _StblPart.offsets());
        case 'stsz':
          sizes = _parseStsz(raw);
          if (recordParts) t.stblParts.add(_StblPart.raw(raw));
        case 'stts':
          final e = _parseStts(raw);
          sttsCounts = e.counts;
          sttsDeltas = e.deltas;
          if (recordParts) t.stblParts.add(_StblPart.raw(raw));
        default:
          if (recordParts) t.stblParts.add(_StblPart.raw(raw));
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
    if (raw.length < 16) throw RepairException('stsc 盒过小（疑似损坏）');
    final cnt = u32AsInt(raw, 12);
    if (cnt <= 0) throw RepairException('stsc 表为空');
    checkTableFits(raw, cnt, 12, 16, 'stsc');
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
    if (raw.length < 16) throw RepairException('stco 盒过小（疑似损坏）');
    final cnt = u32AsInt(raw, 12);
    checkTableFits(raw, cnt, is64 ? 8 : 4, 16, is64 ? 'co64' : 'stco');
    final out = List<int>.filled(cnt, 0);
    var p = 16;
    for (var i = 0; i < cnt; i++) {
      out[i] = is64 ? u64(raw, p) : u32(raw, p);
      p += is64 ? 8 : 4;
    }
    return out;
  }

  List<int> _parseStsz(Uint8List raw) {
    if (raw.length < 20) throw RepairException('stsz 盒过小（疑似损坏）');
    final uniform = u32(raw, 12);
    final cnt = u32AsInt(raw, 16);
    if (uniform == 0) checkTableFits(raw, cnt, 4, 20, 'stsz');
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
    if (raw.length < 16) throw RepairException('stts 盒过小（疑似损坏）');
    final cnt = u32AsInt(raw, 12);
    checkTableFits(raw, cnt, 8, 16, 'stts');
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
        // 不跨 sample description：一个块只能有一个 stsc 描述，否则样本描述会串
        if (i < n && t.descIdx[i] != t.descIdx[start]) break;
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
      switch (p.kind) {
        case _kindStsc:
          stblChildren.add(_buildStsc(t));
        case _kindOffsets:
          stblChildren.add(_buildOffsetsBox(t, useCo64: useCo64, dummy: dummy));
        case _kindStts:
          stblChildren.add(_buildStts(t));
        case _kindStsz:
          stblChildren.add(_buildStsz(t));
        case _kindStss:
          stblChildren.add(_buildStss(t));
        case _kindCtts:
          stblChildren.add(_buildCtts(t));
        default:
          stblChildren.add(p.raw!);
      }
    }
    final stbl = _boxBytes('stbl', _concat(stblChildren));
    final minf = _boxBytes(
      'minf',
      _concat([_concat(t.minfPre), stbl, _concat(t.minfPost)]),
    );

    // 分片转换：按实际样本补全 mdhd / tkhd 时长（普通文件保持原样，不动一字节）
    final mdiaPre = <Uint8List>[];
    for (final raw in t.mdiaPre) {
      var bytes = raw;
      if (t.finalDuration > 0 &&
          bytes.length >= 8 &&
          fourcc(bytes, 4) == 'mdhd') {
        bytes = _patchDuration(
          bytes,
          t.finalDuration,
          v0Offset: 24,
          v1Offset: 32,
        );
      }
      mdiaPre.add(bytes);
    }
    final mdia = _boxBytes('mdia', _concat([_concat(mdiaPre), minf, _concat(t.mdiaPost)]));

    final trakPre = <Uint8List>[];
    for (final raw in t.trakPre) {
      var bytes = raw;
      if (bytes.length >= 8) {
        final type = fourcc(bytes, 4);
        if (t.movieDuration > 0 && type == 'tkhd') {
          bytes = _patchDuration(
            bytes,
            t.movieDuration,
            v0Offset: 28,
            v1Offset: 36,
          );
        }
        if ((t.movieDelayTicks ?? 0) > 0 && type == 'edts') {
          continue; // 由重新生成的空编辑（elst）替代
        }
      }
      trakPre.add(bytes);
    }
    if ((t.movieDelayTicks ?? 0) > 0) trakPre.add(_buildEdts(t));

    return _boxBytes('trak', _concat([_concat(trakPre), mdia, _concat(t.trakPost)]));
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

  /// 由样本时长重建 stts（行程编码）。
  Uint8List _buildStts(_Track t) {
    final entries = <List<int>>[]; //（count, delta）
    for (var i = 0; i < t.deltas.length; i++) {
      final d = t.deltas[i];
      if (entries.isEmpty || entries.last[1] != d) {
        entries.add([1, d]);
      } else {
        entries.last[0]++;
      }
    }
    final payload = Uint8List(8 + entries.length * 8);
    putU32(payload, 0, 0);
    putU32(payload, 4, entries.length);
    var o = 8;
    for (final e in entries) {
      putU32(payload, o, e[0]);
      putU32(payload, o + 4, e[1]);
      o += 8;
    }
    return _boxBytes('stts', payload);
  }

  /// 由样本大小重建 stsz（全等时用 uniform 形式，省空间）。
  Uint8List _buildStsz(_Track t) {
    final n = t.sizes.length;
    var uniform = 0;
    if (n > 0) {
      uniform = t.sizes[0];
      for (var i = 1; i < n; i++) {
        if (t.sizes[i] != uniform) {
          uniform = 0;
          break;
        }
      }
    }
    if (uniform != 0) {
      final payload = Uint8List(12);
      putU32(payload, 0, 0);
      putU32(payload, 4, uniform);
      putU32(payload, 8, n);
      return _boxBytes('stsz', payload);
    }
    final payload = Uint8List(12 + n * 4);
    putU32(payload, 0, 0);
    putU32(payload, 4, 0);
    putU32(payload, 8, n);
    var o = 12;
    for (var i = 0; i < n; i++) {
      putU32(payload, o, t.sizes[i]);
      o += 4;
    }
    return _boxBytes('stsz', payload);
  }

  /// 由同步标记重建 stss（空表 = 全部样本都是同步样本）。
  Uint8List _buildStss(_Track t) {
    final entries = t.stssEntries;
    final payload = Uint8List(8 + entries.length * 4);
    putU32(payload, 0, 0);
    putU32(payload, 4, entries.length);
    var o = 8;
    for (final v in entries) {
      putU32(payload, o, v);
      o += 4;
    }
    return _boxBytes('stss', payload);
  }

  /// 由合成偏移重建 ctts（有负值时用 version 1）。
  Uint8List _buildCtts(_Track t) {
    final values = t.cto;
    final runs = <List<int>>[]; //（count, value）
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (runs.isEmpty || runs.last[1] != v) {
        runs.add([1, v]);
      } else {
        runs.last[0]++;
      }
    }
    final anyNegative = values.any((v) => v < 0);
    final payload = Uint8List(8 + runs.length * 8);
    putU32(payload, 0, anyNegative ? 0x01000000 : 0);
    putU32(payload, 4, runs.length);
    var o = 8;
    for (final r in runs) {
      putU32(payload, o, r[0]);
      putU32(payload, o + 4, r[1] & 0xFFFFFFFF);
      o += 8;
    }
    return _boxBytes('ctts', payload);
  }

  /// 空编辑（elst）：用「延迟 + 正常播放」保留轨道间的起点差。
  Uint8List _buildEdts(_Track t) {
    final delay = t.movieDelayTicks ?? 0;
    final dur = t.movieDuration;
    final payload = Uint8List(8 + 24);
    putU32(payload, 0, 0); // version 0 / flags
    putU32(payload, 4, 2); // entry_count
    // entry 1：空编辑（media_time = -1）
    putU32(payload, 8, delay);
    putU32(payload, 12, 0xFFFFFFFF);
    putU32(payload, 16, 0x00010000); // rate 1.0
    // entry 2：正常播放（媒体时间从 0 起）
    putU32(payload, 20, dur);
    putU32(payload, 24, 0);
    putU32(payload, 28, 0x00010000); // rate 1.0
    return _boxBytes('edts', _boxBytes('elst', payload));
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

  /// 就地补全盒子的时长字段（mdhd / mvhd：v0@24、v1@32；tkhd：v0@28、v1@36），
  /// 只在现有值偏小（常见为 0 / 占位）时改写。
  Uint8List _patchDuration(
    Uint8List box,
    int newDuration, {
    required int v0Offset,
    required int v1Offset,
  }) {
    if (box.length < 12 || newDuration <= 0) return box;
    final ver = box[8];
    final offset = ver == 1 ? v1Offset : v0Offset;
    final size = ver == 1 ? 8 : 4;
    if (box.length < offset + size) return box;
    final current = ver == 1 ? u64(box, offset) : u32(box, offset);
    if (newDuration <= current) return box;
    if (ver == 1) {
      putU64(box, offset, newDuration);
    } else {
      if (newDuration > _u32Max) return box;
      putU32(box, offset, newDuration);
    }
    return box;
  }

  /// 读取 mvhd / mdhd 的 timescale（v0@20、v1@28，均为 32 位）。
  int _boxTimescale(Uint8List box) {
    if (box.length < 24) return 0;
    final offset = box[8] == 1 ? 28 : 20;
    if (box.length < offset + 4) return 0;
    return u32(box, offset);
  }

  /// 读取有符号 32 位（ctts 的合成偏移）。
  int _s32Int(Uint8List b, int o) {
    final v = u32(b, o);
    return v >= 0x80000000 ? v - 0x100000000 : v;
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
  const _StblPart.stts()
      : kind = Mp4Repair._kindStts,
        raw = null;
  const _StblPart.stsz()
      : kind = Mp4Repair._kindStsz,
        raw = null;
  const _StblPart.stss()
      : kind = Mp4Repair._kindStss,
        raw = null;
  const _StblPart.ctts()
      : kind = Mp4Repair._kindCtts,
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

  // ---------------------------------------------------------- 分片转换用
  /// tkhd 里的 track_ID。
  int? trackId;

  /// 原始首样本解码时间（媒体时间基；用于计算 elst 延迟）。
  int firstDtsAbs = 0;

  /// stbl 原有的 ctts（展开成逐样本值，仅混合文件）。
  List<int>? classicCto;

  /// stbl 原有的 stss（1 起样本号，仅混合文件）。
  List<int> origStss = const [];
  bool hasOrigStss = false;

  /// 重新生成的 stss 条目（1 起样本号）。
  List<int> stssEntries = const [];
  bool needStss = false;

  /// 合成偏移（逐样本，ctts 用）。
  List<int> cto = const [];
  bool hasCto = false;

  /// 总时长（媒体时间基 / 影片时间基）与 elst 延迟（影片时间基）。
  int finalDuration = 0;
  int movieDuration = 0;
  int? movieDelayTicks;
}
