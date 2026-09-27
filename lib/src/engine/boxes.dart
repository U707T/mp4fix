import 'dart:typed_data';

import 'binary.dart';
import 'seekable_input.dart';

/// MP4 盒子（box）的基本描述：类型、起始、头部长度（8 或 16）、总大小。
class Box {
  const Box(this.type, this.start, this.header, this.size);

  /// 4 字节类型标识（如 `moov` / `trak` / `stsz`）。
  final String type;

  /// 盒子在文件中的起始偏移。
  final int start;

  /// 头部长度：8（32 位 size）或 16（64 位 largesize）。
  final int header;

  /// 盒子总大小（含头部）。
  final int size;

  int get payloadStart => start + header;
  int get end => start + size;

  @override
  String toString() => 'Box($type, start=$start, size=$size)';
}

/// 顺序扫描 `[from, to)` 内的顶层盒子；遇到不自洽的盒子（越界 / 过小）即停止，
/// 以此容忍尾部的垃圾数据。
List<Box> readBoxes(SeekableInput input, int from, int to) {
  final list = <Box>[];
  var pos = from;
  while (pos + 8 <= to) {
    final hdr = readBytes(input, pos, 8);
    var size = u32(hdr, 0);
    var header = 8;
    final type = fourcc(hdr, 4);
    if (size == 1) {
      if (pos + 16 > to) break;
      final ext = readBytes(input, pos + 8, 8);
      size = u64(ext, 0);
      header = 16;
    } else if (size == 0) {
      size = to - pos;
    }
    if (size < header || pos + size > to) break; // 容忍尾部垃圾
    list.add(Box(type, pos, header, size));
    pos += size;
  }
  return list;
}

/// 完整读取 [size] 字节（循环直到读满）。
Uint8List readBytes(SeekableInput input, int offset, int size) {
  if (size < 0 || size > (1 << 30)) throw RepairException('盒大小异常');
  final out = Uint8List(size);
  var got = 0;
  while (got < size) {
    final n = input.read(offset + got, out, got, size - got);
    if (n <= 0) throw RepairException('读取文件失败（文件可能被截断）');
    got += n;
  }
  return out;
}
