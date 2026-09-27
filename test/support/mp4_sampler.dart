import 'dart:io';
import 'dart:typed_data';

/// **独立实现**的 MP4 采样表读取器（刻意不复用被测引擎的代码）。
///
/// 用于交叉验证「无损修复」：修复前后逐样本比较 大小 / 时间戳 / 描述索引 / 载荷字节。
class TrackSamples {
  TrackSamples(this.index, this.timescale, this.isVideo, this.isAudio);

  final int index;
  final int timescale;
  final bool isVideo;
  final bool isAudio;

  final List<int> sizes = [];
  final List<int> dts = [];
  final List<int> offsets = [];
  final List<int> descIdx = [];

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

  /// 读取文件里所有轨道的采样表（不含载荷读取，载荷见 [TrackSamples.payload]）。
  static List<TrackSamples> read(File file) {
    final raf = file.openSync();
    try {
      final size = raf.lengthSync();
      final top = _boxes(raf, 0, size);
      _Box? moov;
      for (final b in top) {
        if (b.type == 'moov') moov = b;
      }
      if (moov == null) throw StateError('无 moov');

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
        final stsz = _child(raf, stbl, 'stsz');
        final stts = _child(raf, stbl, 'stts');
        final stsc = _child(raf, stbl, 'stsc');
        final stco = _child(raf, stbl, 'stco');
        final co64 = _child(raf, stbl, 'co64');
        if (stsz == null || stts == null || stsc == null) continue;

        // stsz
        final szRaw = _read(raf, stsz.start, stsz.size);
        final uniform = _u32(szRaw, 12);
        final n = _u32(szRaw, 16);
        for (var i = 0; i < n; i++) {
          t.sizes.add(uniform != 0 ? uniform : _u32(szRaw, 20 + i * 4));
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
        tracks.add(t);
      }
      return tracks;
    } finally {
      raf.closeSync();
    }
  }
}
