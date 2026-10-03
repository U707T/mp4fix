import 'dart:typed_data';

import '../engine/engine.dart';
import 'webdav_client.dart';

/// 预取的一段字节（[start] 为文件内绝对偏移）。
class PrefetchRange {
  const PrefetchRange(this.start, this.bytes);

  final int start;
  final Uint8List bytes;
}

/// 远程检测用的"预取输入"。
///
/// 引擎的 [SeekableInput.read] 是同步的，而 WebDAV 读取是异步的 —— 因此这里先把
/// **检测所需的全部区域**（每个顶层盒的头部 + 整个 moov + 分片 MP4 的每个 moof）
/// 异步取回内存，之后引擎的同步随机读取直接命中内存。
/// 检测器只读取这些区域（不读样本数据），因此预取即全部。
class PrefetchedSeekableInput implements SeekableInput {
  PrefetchedSeekableInput({
    required this.size,
    required List<PrefetchRange> ranges,
  }) {
    // 排序 + 合并重叠 / 相邻区间（moov 头与载荷、moof 的头部与整盒会互相重叠）。
    final sorted = List<PrefetchRange>.of(ranges)
      ..sort((a, b) => a.start.compareTo(b.start));
    final merged = <PrefetchRange>[];
    for (final r in sorted) {
      if (merged.isNotEmpty) {
        final last = merged.last;
        final lastEnd = last.start + last.bytes.length;
        if (r.start <= lastEnd) {
          final newEnd = r.start + r.bytes.length;
          if (newEnd > lastEnd) {
            final grown = Uint8List(newEnd - last.start);
            grown.setRange(0, last.bytes.length, last.bytes);
            grown.setRange(
              lastEnd - last.start,
              newEnd - last.start,
              r.bytes,
              lastEnd - r.start,
            );
            merged[merged.length - 1] = PrefetchRange(last.start, grown);
          }
          continue;
        }
      }
      merged.add(r);
    }
    _ranges = merged;
    for (final r in _ranges) {
      _totalBytes += r.bytes.length;
    }
  }

  @override
  final int size;

  late final List<PrefetchRange> _ranges;

  int _totalBytes = 0;

  /// 预取到的总字节数（用于统计 / 展示）。
  int get prefetchedBytes => _totalBytes;

  @override
  int read(int offset, Uint8List buf, int off, int len) {
    if (offset >= size) return -1;
    if (len <= 0) return 0;
    final toRead = (size - offset).clamp(0, len);
    var done = 0;
    while (done < toRead) {
      final pos = offset + done;
      final r = _rangeAt(pos);
      if (r == null) {
        throw RepairException('预取数据缺失（内部错误：offset=$pos）');
      }
      final inRange = pos - r.start;
      final n = (r.bytes.length - inRange).clamp(0, toRead - done);
      if (n <= 0) {
        throw RepairException('预取数据缺失（内部错误：offset=$pos）');
      }
      buf.setRange(off + done, off + done + n, r.bytes, inRange);
      done += n;
    }
    return done;
  }

  PrefetchRange? _rangeAt(int pos) {
    // 区间已排序且互不重叠：二分找到最后一个 start <= pos 的区间
    var lo = 0;
    var hi = _ranges.length - 1;
    var best = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_ranges[mid].start <= pos) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (best < 0) return null;
    final r = _ranges[best];
    return pos < r.start + r.bytes.length ? r : null;
  }

  @override
  void close() {
    // 内存对象，无需释放
  }
}

/// 预取"检测所需区域"，返回可直接交给 [Mp4Inspect] 的输入。
///
/// 算法：从 0 开始顺序扫描顶层盒子，**按窗口取回**（默认 16KB）：
///  - 先取一个窗口，窗口里的字节天然覆盖「连续几个小盒」（ftyp / moov / mdat 头…）；
///  - `moov` 整盒取回；分片 MP4 的每个 `moof` 也整盒取回（引擎靠它读出样本
///    大小 / 时长 / 交错距离）；
///  - 窗口内已覆盖的区域直接复用 —— 分片文件（moof 通常只有几百字节）每个
///    分片只有 1 个请求，而不是头部 + 载荷 + mdat 头 3 个。
///
/// 几 GB 的普通远端文件通常只需个位数请求；分片 MP4 会多出"每个分片 1 个请求、
/// 每个窗口几 KB~16KB"的流量，仍远小于整档下载。
Future<PrefetchedSeekableInput> prefetchForInspect(
  WebDavClient client,
  String url, {
  required int fileSize,
  int maxMoovBytes = 256 << 20,
  int maxMoofBytes = 64 << 20,
  int maxFragments = 20000,
  int windowBytes = 16 << 10,
  bool Function()? isCancelled,
}) async {
  final ranges = <PrefetchRange>[];
  var pos = 0;
  var boxCount = 0;
  var moofCount = 0;

  // 最近取回的连续窗口（顺序扫描时用来"顺路"覆盖后面的小盒）
  Uint8List? cover;
  var coverStart = 0;
  var coverEnd = 0;

  Future<void> ensureCover(int start) async {
    if (cover != null && start >= coverStart && start < coverEnd) return;
    final endInclusive = start + windowBytes - 1 < fileSize - 1
        ? start + windowBytes - 1
        : fileSize - 1;
    final bytes = await client.getRange(url, start, endInclusive);
    if (bytes.isEmpty) throw WebDavException('预取读取为空（服务器异常？）');
    cover = bytes;
    coverStart = start;
    coverEnd = start + bytes.length;
    ranges.add(PrefetchRange(start, bytes));
  }

  while (pos + 8 <= fileSize) {
    if (isCancelled?.call() ?? false) throw WebDavException('已取消');
    if (++boxCount > 50000) break; // 异常文件保护
    await ensureCover(pos);

    final off = pos - coverStart;
    final avail = coverEnd - pos;
    if (avail < 8) break;
    var size = u32(cover!, off);
    var header = 8;
    final type = fourcc(cover!, off + 4);
    if (size == 1) {
      if (avail < 16) break;
      size = u64(cover!, off + 8);
      header = 16;
    } else if (size == 0) {
      size = fileSize - pos;
    }
    if (size < header || pos + size > fileSize) break; // 容忍尾部垃圾（引擎同样）

    if (type == 'moov' || type == 'moof') {
      if (type == 'moov' && size - header > maxMoovBytes) {
        throw WebDavException(
          'moov 过大（${formatBytes(size - header)}），已跳过远程检测',
        );
      }
      if (type == 'moof') {
        if (++moofCount > maxFragments) {
          throw WebDavException(
            '分片（fragmented）MP4 分片数过多（>$maxFragments），'
            '已跳过远程检测（建议下载到本地处理）',
          );
        }
        if (size - header > maxMoofBytes) {
          throw WebDavException(
            'moof 过大（${formatBytes(size - header)}），已跳过远程检测',
          );
        }
      }
      // 补齐整盒（窗口可能不够；每段仍按窗口大小取，末段顺路多取一点）
      final boxEnd = pos + size;
      while (coverEnd < boxEnd) {
        if (isCancelled?.call() ?? false) throw WebDavException('已取消');
        final start2 = coverEnd;
        final endInclusive = start2 + windowBytes - 1 < fileSize - 1
            ? start2 + windowBytes - 1
            : fileSize - 1;
        final bytes = await client.getRange(url, start2, endInclusive);
        if (bytes.isEmpty) throw WebDavException('预取读取为空（服务器异常？）');
        cover = bytes;
        coverStart = start2;
        coverEnd = start2 + bytes.length;
        ranges.add(PrefetchRange(start2, bytes));
      }
    }
    pos += size;
  }
  return PrefetchedSeekableInput(size: fileSize, ranges: ranges);
}
