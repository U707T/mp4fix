import 'dart:io';
import 'dart:typed_data';

/// 支持随机读取的数据源（本地文件 / 内存 / WebDAV Range 等）。
///
/// 这是 MP4 引擎与外部世界之间唯一的 IO 抽象 —— 引擎本身不关心数据来自
/// 文件、内存还是网络，只按偏移读取字节。
abstract class SeekableInput {
  /// 数据源总字节数。
  int get size;

  /// 从绝对偏移 [offset] 读取最多 [len] 字节到 [buf] 的 `buf[off..off+len]`。
  ///
  /// 返回实际读取的字节数；已到 EOF 返回 -1（与 Kotlin 版语义一致）。
  int read(int offset, Uint8List buf, int off, int len);

  /// 释放底层资源（幂等，可重复调用）。
  void close();
}

/// 基于本地文件的随机读取实现。
class FileSeekableInput implements SeekableInput {
  FileSeekableInput(File file) : _raf = file.openSync(mode: FileMode.read);

  final RandomAccessFile _raf;
  bool _closed = false;

  @override
  int get size => _closed ? 0 : _raf.lengthSync();

  @override
  int read(int offset, Uint8List buf, int off, int len) {
    if (_closed || len <= 0) return -1;
    var total = 0;
    while (total < len) {
      _raf.setPositionSync(offset + total);
      final n = _raf.readIntoSync(buf, off + total, off + len);
      if (n <= 0) break;
      total += n;
    }
    return total == 0 ? -1 : total;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _raf.closeSync();
    } catch (_) {
      // 忽略重复关闭 / 已失效
    }
  }
}

/// 基于内存字节数组的随机读取实现（测试与小文件用）。
class BytesSeekableInput implements SeekableInput {
  BytesSeekableInput(this.bytes);

  final Uint8List bytes;

  @override
  int get size => bytes.length;

  @override
  int read(int offset, Uint8List buf, int off, int len) {
    if (offset >= bytes.length) return -1;
    if (len <= 0) return 0;
    final toRead = (bytes.length - offset).clamp(0, len);
    buf.setRange(off, off + toRead, bytes, offset);
    return toRead;
  }

  @override
  void close() {}
}
