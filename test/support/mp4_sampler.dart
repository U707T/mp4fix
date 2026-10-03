import 'dart:io';
import 'dart:typed_data';

/// **独立实现**的 MP4 采样表读取器（刻意不复用被测引擎的代码）。
///
/// 用于交叉验证「无损修复」：修复前后逐样本比较 大小 / 时间戳 / 描述索引 /
/// 同步标记 / 载荷字节。分片（fragmented）MP4 也可读取（解析 moof/traf/trun；
/// 时间戳按轨道归一化到 0 起，与修复产物一致）。
class TrackSamples {
  TrackSamples(this.index, this.timescale, this.isVideo, this.isAudio);

  final int index;
  final int timescale;
  final bool isVideo;
  final bool isAudio;

  /// tkhd 里的 track_ID（分片文件用来关联 moof）。
  int trackId = 0;

  final List<int> sizes = [];
  final List<int> dts = [];
  final List<int> offsets = [];
  final List<int> descIdx = [];

  /// 是否同步样本（stss / trun 标记；没有任何信息时视为全同步）。
  final List<bool> sync = [];

  int get count => sizes.length;

  /// 按样本顺序拼接的载荷字节。
  Uint8List payload(RandomAccessFile raf) {
    final total = sizes.fold<int>(0, (a, b) => a + b);
    final out = Uint8List(total);
    var written = 0;
    for (var i = 0; i < count; i++) {
      raf.setPositionSync(offsets[i]);
      final buf = raf.readSync(sizes[i]);
      out.setRange(written, written + buf.length, buf);
      written += buf.length;
    }
    return out;
  }
}

class _Box {
  _Box(this.type, this.start, this.header, this.size);
  final String type;
  final int start;
  final int header;
  final int size;
  int get payloadStart => start + header;
  int get end => start + size;
}

/// trex 默认值：分片内未显式给出的字段从这里取。
class _Trex {
  _Trex(this.sdi, this.dur, this.size, this.flags);
  final int sdi;
  final int dur;
  final int size;
  final int flags;
}

/// 单个轨道累积的分片样本。
class _FragBuffer {
  final List<int> sizes = [];
  final List<int> dts = [];
  final List<int> offsets = [];
  final List<int> descIdx = [];
  final List<bool> sync = [];
  int nextDts = 0;
  bool get isEmpty => sizes.isEmpty;
}

class Mp4Sampler {
  static int _u32(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _u64(Uint8List b, int o) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | b[o + i];
    }
    return v;
  }

  static int _s32(Uint8List b, int o) {
    final v = _u32(b, o);
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }

  static Uint8List _read(RandomAccessFile raf, int offset, int len) {
    raf.setPositionSync(offset);
    final out = raf.readSync(len);
    if (out.length != len) {
      throw StateError('读取越界：offset=$offset len=$len got=${out.length}');
    }
    return out;
  }

  static List<_Box> _boxes(RandomAccessFile raf, int from, int to) {
    final out = <_Box>[];
    var pos = from;
    while (pos + 8 <= to) {
      final hdr = _read(raf, pos, 8);
      var size = _u32(hdr, 0);
      var header = 8;
      final type = String.fromCharCodes(hdr, 4, 8);
      if (size == 1) {
        final ext = _read(raf, pos + 8, 8);
        size = _u64(ext, 0);
        header = 16;
      } else if (size == 0) {
        size = to - pos;
      }
      if (size < header || pos + size > to) break;
      out.add(_Box(type, pos, header, size));
      pos += size;
    }
    return out;
  }

  static _Box? _child(RandomAccessFile raf, _Box parent, String type) {
    for (final b in _boxes(raf, parent.payloadStart, parent.end)) {
      if (b.type == type) return b;
    }
    return null;
  }

  /// 读取 trex 默认值（按 track_ID）。
  static Map<int, _Trex> _trexDefaults(RandomAccessFile raf, _Box moov) {
    final out = <int, _Trex>{};
    final mvex = _child(raf, moov, 'mvex');
    if (mvex == null) return out;
    for (final b in _boxes(raf, mvex.payloadStart, mvex.end)) {
      if (b.type != 'trex') continue;
      final raw = _read(raf, b.start, b.size);
      out[_u32(raw, 12)] =
          _Trex(_u32(raw, 16), _u32(raw, 20), _u32(raw, 24), _u32(raw, 28));
    }
    return out;
  }

  /// 读取文件里所有轨道的采样（不含载荷读取，载荷见 [TrackSamples.payload]）。
  static List<TrackSamples> read(File file) {
    final raf = file.openSync();
    try {
      final size = raf.lengthSync();
      final top = _boxes(raf, 0, size);
      _Box? moov;
      var hasMoofs = false;
      for (final b in top) {
        if (b.type == 'moov') moov = b;
        if (b.type == 'moof') hasMoofs = true;
      }
      if (moov == null) throw StateError('无 moov');
      final trex = _trexDefaults(raf, moov);

      final tracks = <TrackSamples>[];
      var index = 0;
      for (final trak in _boxes(raf, moov.payloadStart, moov.end)) {
        if (trak.type != 'trak') continue;
        final mdia = _child(raf, trak, 'mdia');
        if (mdia == null) continue;
        final mdhd = _child(raf, mdia, 'mdhd');
        final minf = _child(raf, mdia, 'minf');
        if (mdhd == null || minf == null) continue;
        final stbl = _child(raf, minf, 'stbl');
        if (stbl == null) continue;

        final mdhdRaw = _read(raf, mdhd.start, mdhd.size);
        final ver = mdhdRaw[8];
        final timescale = ver == 1 ? _u32(mdhdRaw, 28) : _u32(mdhdRaw, 20);

        bool isVideo = false;
        bool isAudio = false;
        final hdlr = _child(raf, mdia, 'hdlr');
        if (hdlr != null) {
          final hr = _read(raf, hdlr.start, hdlr.size < 24 ? hdlr.size : 24);
          final handler = String.fromCharCodes(hr, 16, 20);
          isVideo = handler == 'vide';
          isAudio = handler == 'soun';
        }

        final t = TrackSamples(index++, timescale, isVideo, isAudio);

        // track_ID（分片关联）
        final tkhd = _child(raf, trak, 'tkhd');
        if (tkhd != null) {
          final tr = _read(raf, tkhd.start, tkhd.size < 32 ? tkhd.size : 32);
          if (tr.length >= 24) {
            t.trackId = tr[8] == 1
                ? (tr.length >= 32 ? _u32(tr, 28) : 0)
                : _u32(tr, 20);
          }
        }

        // ---- 普通采样表（分片文件的 moov 表通常为空；非空时照常读取）
        final stsz = _child(raf, stbl, 'stsz');
        if (stsz != null) {
          final szRaw = _read(raf, stsz.start, stsz.size);
          final uniform = _u32(szRaw, 12);
          final n = _u32(szRaw, 16);
          if (n > 0) {
            _readTableSamples(raf, t, stbl, szRaw, uniform, n);
          }
        }

        // ---- 同步样本表（没有 stss = 全部同步）
        final stss = _child(raf, stbl, 'stss');
        if (stss != null && t.count > 0) {
          final ssRaw = _read(raf, stss.start, stss.size);
          final cnt = _u32(ssRaw, 12);
          final set = <int>{};
          for (var i = 0; i < cnt; i++) {
            set.add(_u32(ssRaw, 16 + i * 4));
          }
          for (var i = 0; i < t.count; i++) {
            t.sync.add(set.contains(i + 1));
          }
        } else {
          for (var i = 0; i < t.count; i++) {
            t.sync.add(true);
          }
        }
        tracks.add(t);
      }

      if (hasMoofs) _mergeFragments(raf, top, tracks, trex);
      return tracks;
    } finally {
      raf.closeSync();
    }
  }

  /// 普通 stbl 采样表 → 逐样本信息。
  static void _readTableSamples(
    RandomAccessFile raf,
    TrackSamples t,
    _Box stbl,
    Uint8List szRaw,
    int uniform,
    int n,
  ) {
    for (var i = 0; i < n; i++) {
      t.sizes.add(uniform != 0 ? uniform : _u32(szRaw, 20 + i * 4));
    }

    final stts = _child(raf, stbl, 'stts');
    final stsc = _child(raf, stbl, 'stsc');
    final stco = _child(raf, stbl, 'stco');
    final co64 = _child(raf, stbl, 'co64');
    if (stts == null || stsc == null || (stco == null && co64 == null)) {
      return;
    }

    // stts → dts
    final tsRaw = _read(raf, stts.start, stts.size);
    final tsCount = _u32(tsRaw, 12);
    var dts = 0;
    for (var i = 0; i < tsCount; i++) {
      var c = _u32(tsRaw, 16 + i * 8);
      final d = _u32(tsRaw, 16 + i * 8 + 4);
      while (c-- > 0) {
        t.dts.add(dts);
        dts += d;
      }
    }

    // stsc
    final scRaw = _read(raf, stsc.start, stsc.size);
    final scCount = _u32(scRaw, 12);
    final entries = <List<int>>[];
    for (var i = 0; i < scCount; i++) {
      entries.add([
        _u32(scRaw, 16 + i * 12),
        _u32(scRaw, 16 + i * 12 + 4),
        _u32(scRaw, 16 + i * 12 + 8),
      ]);
    }

    // stco / co64
    final offBox = stco ?? co64!;
    final is64 = stco == null;
    final offRaw = _read(raf, offBox.start, offBox.size);
    final offCount = _u32(offRaw, 12);
    final chunks = <int>[];
    for (var i = 0; i < offCount; i++) {
      chunks.add(is64 ? _u64(offRaw, 16 + i * 8) : _u32(offRaw, 16 + i * 4));
    }

    var s = 0;
    var e = 0;
    for (var ci = 0; ci < chunks.length; ci++) {
      final chunkNo = ci + 1;
      while (e + 1 < entries.length && chunkNo >= entries[e + 1][0]) {
        e++;
      }
      final spc = entries[e][1];
      final desc = entries[e][2];
      var o = chunks[ci];
      for (var k = 0; k < spc; k++) {
        if (s >= t.sizes.length) break;
        t.offsets.add(o);
        t.descIdx.add(desc);
        o += t.sizes[s];
        s++;
      }
    }
  }

  /// 解析全部分片，把样本追加到各轨道（普通表样本在前）。
  static void _mergeFragments(
    RandomAccessFile raf,
    List<_Box> top,
    List<TrackSamples> tracks,
    Map<int, _Trex> trex,
  ) {
    final byId = <int, TrackSamples>{};
    for (final t in tracks) {
      if (t.trackId != 0) byId.putIfAbsent(t.trackId, () => t);
    }
    if (byId.isEmpty) return;
    final buffers = <int, _FragBuffer>{
      for (final id in byId.keys) id: _FragBuffer(),
    };
    for (final b in top) {
      if (b.type == 'moof') _readMoof(raf, b, buffers, trex);
    }
    for (final t in tracks) {
      final f = buffers[t.trackId];
      if (f == null || f.isEmpty) continue;
      final base = t.sizes.isEmpty ? f.dts.first : 0; // 与引擎一致：平移到 0 起
      for (var i = 0; i < f.sizes.length; i++) {
        t.sizes.add(f.sizes[i]);
        t.dts.add(f.dts[i] - base);
        t.offsets.add(f.offsets[i]);
        t.descIdx.add(f.descIdx[i]);
        t.sync.add(f.sync[i]);
      }
    }
  }

  static void _readMoof(
    RandomAccessFile raf,
    _Box moof,
    Map<int, _FragBuffer> out,
    Map<int, _Trex> trex,
  ) {
    final raw = _read(raf, moof.start, moof.size);
    var p = moof.header;
    final end = raw.length;
    int? prevTrafEnd;
    while (p + 8 <= end) {
      final size = _u32(raw, p);
      final type = String.fromCharCodes(raw, p + 4, p + 8);
      if (size < 8 || p + size > end) break;
      if (type == 'traf') {
        prevTrafEnd = _readTraf(raw, p, size, moof.start, out, trex, prevTrafEnd);
      }
      p += size;
    }
  }

  static int? _readTraf(
    Uint8List raw,
    int start,
    int size,
    int moofStart,
    Map<int, _FragBuffer> out,
    Map<int, _Trex> trex,
    int? previousTrafDataEnd,
  ) {
    final end = start + size;
    var p = start + 8;

    int? trackId;
    int? baseDataOffset;
    var defaultBaseIsMoof = false;
    int? defDur;
    int? defSize;
    int? defFlags;
    int? defSdi;
    int? tfdt;
    var tfdtUsed = false;
    int? lastRunEnd;
    int? dataEnd;

    while (p + 8 <= end) {
      final bSize = _u32(raw, p);
      final bType = String.fromCharCodes(raw, p + 4, p + 8);
      if (bSize < 8 || p + bSize > end) break;
      switch (bType) {
        case 'tfhd':
          final flags = _u32(raw, p + 8) & 0xFFFFFF;
          var q = p + 12;
          trackId = _u32(raw, q);
          q += 4;
          if (flags & 0x1 != 0) {
            baseDataOffset = _u64(raw, q);
            q += 8;
          }
          if (flags & 0x2 != 0) {
            defSdi = _u32(raw, q);
            q += 4;
          }
          if (flags & 0x8 != 0) {
            defDur = _u32(raw, q);
            q += 4;
          }
          if (flags & 0x10 != 0) {
            defSize = _u32(raw, q);
            q += 4;
          }
          if (flags & 0x20 != 0) {
            defFlags = _u32(raw, q);
            q += 4;
          }
          defaultBaseIsMoof = flags & 0x020000 != 0;
        case 'tfdt':
          final v = raw[p + 8];
          tfdt = v == 1 ? _u64(raw, p + 12) : _u32(raw, p + 12);
        case 'trun':
          final f = trackId == null ? null : out[trackId];
          if (f == null) break;
          final d = trex[trackId] ?? _Trex(1, 0, 0, 0);
          final flags = _u32(raw, p + 8) & 0xFFFFFF;
          var q = p + 12;
          final count = _u32(raw, q);
          q += 4;
          int? doff;
          if (flags & 0x1 != 0) {
            doff = _s32(raw, q);
            q += 4;
          }
          int? firstFlags;
          if (flags & 0x4 != 0) {
            firstFlags = _u32(raw, q);
            q += 4;
          }
          final base = baseDataOffset ??
              (defaultBaseIsMoof ? moofStart : (previousTrafDataEnd ?? moofStart));
          var off = doff != null ? base + doff : (lastRunEnd ?? base);
          var cursor = (!tfdtUsed && tfdt != null) ? tfdt : f.nextDts;
          tfdtUsed = true;
          for (var i = 0; i < count; i++) {
            int dur;
            if (flags & 0x100 != 0) {
              dur = _u32(raw, q);
              q += 4;
            } else {
              dur = defDur ?? d.dur;
            }
            int sz;
            if (flags & 0x200 != 0) {
              sz = _u32(raw, q);
              q += 4;
            } else {
              sz = defSize ?? d.size;
            }
            int fl;
            if (flags & 0x400 != 0) {
              fl = _u32(raw, q);
              q += 4;
            } else if (i == 0 && firstFlags != null) {
              fl = firstFlags;
            } else {
              fl = defFlags ?? d.flags;
            }
            if (flags & 0x800 != 0) q += 4;
            f.sizes.add(sz);
            f.dts.add(cursor);
            f.offsets.add(off);
            f.descIdx.add(defSdi ?? d.sdi);
            f.sync.add((fl & 0x10000) == 0);
            off += sz;
            cursor += dur;
            f.nextDts = cursor;
          }
          lastRunEnd = off;
          dataEnd = off;
      }
      p += bSize;
    }
    return dataEnd;
  }
}
