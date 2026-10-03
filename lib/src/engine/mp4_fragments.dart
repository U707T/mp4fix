/// 分片（fragmented）MP4 支持 —— moof/traf/trun 解析。
///
/// 分片 MP4（fMP4）把样本分散在若干 `moof`（movie fragment）+ `mdat` 里，
/// 每帧/每包的大小、时长、偏移、同步（关键帧）标记由 `traf` 内的 `trun`
/// 逐条列出；缺省值来自 `tfhd` 与 `mvex/trex`。
///
/// 本模块把这些信息汇总成与普通 MP4 采样表（stts/stsc/stsz/stco/stss）等价
/// 的数据结构，供 [Mp4Inspect]（检测）与 [Mp4Repair]（无损“扁平化”转换）共用。
///
/// 参考 ISO/IEC 14496-12 §8.8（Movie Fragments）。
library;

import 'dart:typed_data';

import 'binary.dart';
import 'boxes.dart';
import 'seekable_input.dart';

/// `mvex/trex` 里的默认值：分片内未显式给出的字段从这里取。
class FragmentTrackDefaults {
  int defaultSampleDescriptionIndex = 1;
  int defaultSampleDuration = 0;
  int defaultSampleSize = 0;
  int defaultSampleFlags = 0;
}

/// 解析 `moov/mvex` 下的全部 `trex`，按 track_ID 索引。
Map<int, FragmentTrackDefaults> parseTrexDefaults(
  SeekableInput input,
  List<Box> moovChildren,
) {
  final out = <int, FragmentTrackDefaults>{};
  for (final b in moovChildren) {
    if (b.type != 'mvex') continue;
    for (final c in readBoxes(input, b.payloadStart, b.end)) {
      if (c.type != 'trex') continue;
      final raw = readBytes(input, c.start, c.size);
      if (raw.length < 32) throw RepairException('trex 盒过小（疑似损坏）');
      out[u32(raw, 12)] = FragmentTrackDefaults()
        ..defaultSampleDescriptionIndex = u32(raw, 16)
        ..defaultSampleDuration = u32(raw, 20)
        ..defaultSampleSize = u32(raw, 24)
        ..defaultSampleFlags = u32(raw, 28);
    }
  }
  return out;
}

/// 单个轨道从全部分片里读出的样本信息（按解码顺序）。
class FragmentTrackSamples {
  FragmentTrackSamples(this.trackId);

  final int trackId;

  /// 样本大小（字节）。
  final List<int> sizes = [];

  /// 样本时长（媒体时间基）。
  final List<int> durations = [];

  /// 样本解码时间（媒体时间基，绝对值；来自 tfdt 累加）。
  final List<int> dts = [];

  /// 样本在文件中的绝对偏移。
  final List<int> offsets = [];

  /// 样本所属的 stsd 描述索引（1 起）。
  final List<int> descIdx = [];

  /// 合成时间偏移（ctts）；未出现时全为 0。
  final List<int> compOffsets = [];

  /// 是否出现过非零合成偏移（决定输出是否需要 ctts）。
  bool hasCompositionOffsets = false;

  /// 是否同步样本（关键帧）。
  final List<bool> sync = [];

  /// 是否出现过非同步样本（决定输出是否需要 stss）。
  bool anyNonSync = false;

  /// 没有 `tfdt` 的分片从这继续（按轨道累计的下一解码时间）。
  int nextDts = 0;

  int get count => sizes.length;
}

/// 读取 [moofs] 内全部 `traf` 的样本，追加到 [tracks]（按 track_ID 分配）。
///
/// 只处理 [tracks] 里已登记的轨道；未知轨道的 `traf` 跳过（容忍混入的
/// hint / 元数据轨）。[defaults] 为 `mvex/trex` 缺省值。
void readFragmentSamples(
  SeekableInput input,
  List<Box> moofs,
  Map<int, FragmentTrackSamples> tracks, {
  Map<int, FragmentTrackDefaults> defaults = const {},
  int maxMoofBytes = 64 << 20,
}) {
  for (final moof in moofs) {
    _readMoof(input, moof, tracks, defaults, maxMoofBytes);
  }
}

void _readMoof(
  SeekableInput input,
  Box moof,
  Map<int, FragmentTrackSamples> tracks,
  Map<int, FragmentTrackDefaults> trex,
  int maxMoofBytes,
) {
  if (moof.size > maxMoofBytes) throw RepairException('moof 盒过大（疑似损坏）');
  final raw = readBytes(input, moof.start, moof.size);
  final end = raw.length;
  var p = moof.header;
  int? lastTrafDataEnd;
  while (p + 8 <= end) {
    final size = u32(raw, p);
    final type = fourcc(raw, p + 4);
    if (size < 8 || p + size > end) {
      throw RepairException('moof 结构异常（疑似损坏）');
    }
    if (type == 'traf') {
      lastTrafDataEnd = _readTraf(
        input,
        raw,
        p,
        size,
        moof.start,
        tracks,
        trex,
        lastTrafDataEnd,
      );
    }
    p += size;
  }
}

/// 解析一个 `traf` 的子盒（tfhd / tfdt / trun）。
///
/// 返回本 traf 数据末端（绝对偏移），供同一 moof 内下一个 traf 在
/// 未显式给出 base-data-offset 时接续。
int? _readTraf(
  SeekableInput input,
  Uint8List raw,
  int start,
  int size,
  int moofStart,
  Map<int, FragmentTrackSamples> tracks,
  Map<int, FragmentTrackDefaults> trex,
  int? previousTrafDataEnd,
) {
  final end = start + size;
  final fileSize = input.size;
  var p = start + 8;

  int? trackId;
  int? baseDataOffset;
  var defaultBaseIsMoof = false;
  int? defaultDuration;
  int? defaultSize;
  int? defaultFlags;
  int? defaultDescIdx;
  int? tfdtValue;
  var tfdtUsed = false;

  int? lastRunEnd; // traf 内上一个 run 的数据末端（绝对偏移）
  int? dataEnd; // 本 traf 全部分片数据的末端

  while (p + 8 <= end) {
    final bSize = u32(raw, p);
    final bType = fourcc(raw, p + 4);
    if (bSize < 8 || p + bSize > end) {
      throw RepairException('traf 结构异常（疑似损坏）');
    }
    switch (bType) {
      case 'tfhd':
        if (p + 12 > p + bSize) throw RepairException('tfhd 盒过小（疑似损坏）');
        final flags = u32(raw, p + 8) & 0x00FFFFFF;
        var q = p + 12;
        if (q + 4 > p + bSize) throw RepairException('tfhd 盒过小（疑似损坏）');
        trackId = u32(raw, q);
        q += 4;
        if (flags & 0x000001 != 0) {
          if (q + 8 > p + bSize) throw RepairException('tfhd 盒过小（疑似损坏）');
          baseDataOffset = u64(raw, q);
          q += 8;
        }
        if (flags & 0x000002 != 0) {
          if (q + 4 > p + bSize) throw RepairException('tfhd 盒过小（疑似损坏）');
          defaultDescIdx = u32(raw, q);
          q += 4;
        }
        if (flags & 0x000008 != 0) {
          if (q + 4 > p + bSize) throw RepairException('tfhd 盒过小（疑似损坏）');
          defaultDuration = u32(raw, q);
          q += 4;
        }
        if (flags & 0x000010 != 0) {
          if (q + 4 > p + bSize) throw RepairException('tfhd 盒过小（疑似损坏）');
          defaultSize = u32(raw, q);
          q += 4;
        }
        if (flags & 0x000020 != 0) {
          if (q + 4 > p + bSize) throw RepairException('tfhd 盒过小（疑似损坏）');
          defaultFlags = u32(raw, q);
          q += 4;
        }
        defaultBaseIsMoof = (flags & 0x020000) != 0;
      case 'tfdt':
        if (p + 12 > p + bSize) throw RepairException('tfdt 盒过小（疑似损坏）');
        final v = raw[p + 8];
        if (v == 1) {
          if (p + 20 > p + bSize) throw RepairException('tfdt 盒过小（疑似损坏）');
          tfdtValue = u64(raw, p + 12);
        } else {
          if (p + 16 > p + bSize) throw RepairException('tfdt 盒过小（疑似损坏）');
          tfdtValue = u32(raw, p + 12);
        }
      case 'trun':
        final t = trackId == null ? null : tracks[trackId];
        if (t == null) break; // 未知轨道：跳过
        final def = trex[trackId] ?? FragmentTrackDefaults();

        if (p + 16 > p + bSize) throw RepairException('trun 盒过小（疑似损坏）');
        final flags = u32(raw, p + 8) & 0x00FFFFFF;
        var q = p + 12;
        if (q + 4 > p + bSize) throw RepairException('trun 盒过小（疑似损坏）');
        final sampleCount = u32AsInt(raw, q);
        q += 4;
        int? dataOffset;
        if (flags & 0x000001 != 0) {
          if (q + 4 > p + bSize) throw RepairException('trun 盒过小（疑似损坏）');
          dataOffset = _s32(raw, q);
          q += 4;
        }
        int? firstSampleFlags;
        if (flags & 0x000004 != 0) {
          if (q + 4 > p + bSize) throw RepairException('trun 盒过小（疑似损坏）');
          firstSampleFlags = u32(raw, q);
          q += 4;
        }
        final perSample = _trunEntrySize(flags);
        if (q + sampleCount * perSample > p + bSize) {
          throw RepairException('trun 表长度异常（疑似损坏）');
        }

        // 数据起点：相对 base（默认-base-is-moof 时即 moof 起点）；
        // 未给 data_offset 时接在上一 run 之后（首个 run 则从 base 开始）。
        final base = baseDataOffset ??
            (defaultBaseIsMoof ? moofStart : (previousTrafDataEnd ?? moofStart));
        final runStart =
            dataOffset != null ? base + dataOffset : (lastRunEnd ?? base);
        if (runStart < 0) throw RepairException('分片数据偏移异常（疑似损坏）');

        var cursor = (!tfdtUsed && tfdtValue != null) ? tfdtValue : t.nextDts;
        tfdtUsed = true;
        var off = runStart;

        for (var i = 0; i < sampleCount; i++) {
          int dur;
          if (flags & 0x000100 != 0) {
            dur = u32(raw, q);
            q += 4;
          } else {
            dur = defaultDuration ?? def.defaultSampleDuration;
          }
          int sz;
          if (flags & 0x000200 != 0) {
            sz = u32(raw, q);
            q += 4;
          } else {
            sz = defaultSize ?? def.defaultSampleSize;
          }
          int fl;
          if (flags & 0x000400 != 0) {
            fl = u32(raw, q);
            q += 4;
          } else if (i == 0 && firstSampleFlags != null) {
            fl = firstSampleFlags;
          } else {
            fl = defaultFlags ?? def.defaultSampleFlags;
          }
          var cto = 0;
          if (flags & 0x000800 != 0) {
            cto = _s32(raw, q);
            q += 4;
          }

          if (dur <= 0) {
            throw RepairException('分片样本缺少时长（duration）信息，无法转换');
          }
          final sampleEnd = off + sz;
          if (off < 0 || sampleEnd > fileSize) {
            throw RepairException('分片样本数据越界（文件可能被截断）');
          }

          t.sizes.add(sz);
          t.durations.add(dur);
          t.dts.add(cursor);
          t.offsets.add(off);
          t.descIdx.add(defaultDescIdx ?? def.defaultSampleDescriptionIndex);
          t.compOffsets.add(cto);
          if (cto != 0) t.hasCompositionOffsets = true;
          final isSync = (fl & 0x00010000) == 0;
          t.sync.add(isSync);
          if (!isSync) t.anyNonSync = true;

          off = sampleEnd;
          cursor += dur;
          t.nextDts = cursor;
        }
        lastRunEnd = off;
        dataEnd = off;
    }
    p += bSize;
  }
  return dataEnd;
}

/// trun 中每个样本条目占用的字节数（按 flags 里出现的字段）。
int _trunEntrySize(int flags) {
  var n = 0;
  if (flags & 0x000100 != 0) n += 4; // sample duration
  if (flags & 0x000200 != 0) n += 4; // sample size
  if (flags & 0x000400 != 0) n += 4; // sample flags
  if (flags & 0x000800 != 0) n += 4; // composition time offset
  return n;
}

/// 读取有符号 32 位（data_offset / composition time offset）。
int _s32(Uint8List b, int o) {
  final v = u32(b, o);
  return v >= 0x80000000 ? v - 0x100000000 : v;
}
