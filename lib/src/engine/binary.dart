import 'dart:io';
import 'dart:typed_data';

/// 引擎操作失败（消息面向用户展示）。
class RepairException implements Exception {
  RepairException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'RepairException: $message';
}

/// 用户取消操作。
class RepairCancelledException implements Exception {
  RepairCancelledException();

  @override
  String toString() => '已取消';
}

/// 调试开关：构建时 `--dart-define=mp4fix.debug=true`。
const bool kMp4FixDebug = bool.fromEnvironment('mp4fix.debug');

// ---------------------------------------------------------------- 无符号读取

int u32(Uint8List b, int o) =>
    ((b[o] & 0xff) << 24) |
    ((b[o + 1] & 0xff) << 16) |
    ((b[o + 2] & 0xff) << 8) |
    (b[o + 3] & 0xff);

int u64(Uint8List b, int o) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | (b[o + i] & 0xff);
  }
  return v;
}

/// 读取 32 位字段并要求其可放进有符号 32 位（否则视为文件异常）。
int u32AsInt(Uint8List b, int o) {
  final v = u32(b, o);
  if (v > 0x7FFFFFFF) throw RepairException('字段数值异常');
  return v;
}

/// 读取 4 字节 box/codec 标识（ISO-8859-1）。
String fourcc(Uint8List b, int o) => String.fromCharCodes(b, o, o + 4);

// ---------------------------------------------------------------- 写入

void putU32(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xff;
  b[o + 1] = (v >> 16) & 0xff;
  b[o + 2] = (v >> 8) & 0xff;
  b[o + 3] = v & 0xff;
}

void putU64(Uint8List b, int o, int v) {
  for (var i = 0; i < 8; i++) {
    b[o + i] = (v >> (56 - i * 8)) & 0xff;
  }
}

/// ASCII / ISO-8859-1 字符串转字节。
Uint8List asciiBytes(String s) => Uint8List.fromList(s.codeUnits);

// ---------------------------------------------------------------- 输出抽象

/// 引擎写出用的同步字节汇（与 [SeekableInput] 对偶）。
///
/// 引擎保持同步实现（便于在 Isolate 中整段运行 / 单元测试），
/// 异步 IO（SAF、上传等）由调用方在引擎外处理。
abstract class SyncSink {
  void write(Uint8List data, [int start = 0, int? end]);

  void flush();
}

/// 写入本地文件（顺序写出）。
class FileSyncSink implements SyncSink {
  FileSyncSink(this._raf);

  final RandomAccessFile _raf;
  bool _closed = false;

  @override
  void write(Uint8List data, [int start = 0, int? end]) {
    if (_closed) throw StateError('sink 已关闭');
    _raf.writeFromSync(data, start, end);
  }

  @override
  void flush() {
    // RandomAccessFile 为同步直写，无用户态缓冲。
  }

  /// 关闭底层文件。
  void close() {
    if (_closed) return;
    _closed = true;
    _raf.closeSync();
  }
}

/// 写入内存（测试用）。
class BytesSyncSink implements SyncSink {
  // copy: true —— add() 时复制，避免与调用方复用的缓冲区产生别名。
  final BytesBuilder _builder = BytesBuilder();

  int length = 0;

  @override
  void write(Uint8List data, [int start = 0, int? end]) {
    final e = end ?? data.length;
    _builder.add(Uint8List.sublistView(data, start, e));
    length += e - start;
  }

  @override
  void flush() {}

  Uint8List takeBytes() => _builder.takeBytes();
}

/// 便于调试的 `[dbg]` 日志（仅在 dart-define 开启时输出）。
void debugLog(String message) {
  if (kMp4FixDebug) {
    // ignore: avoid_print
    print('[dbg] $message');
  }
}

/// 统一提取异常消息（面向用户展示）。
String errorMessage(Object e) => e is RepairException ? e.message : e.toString();

/// 显示用字节格式化（与 Kotlin 版 `fmtBytes` 一致）。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
