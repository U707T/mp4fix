import 'dart:io';

import '../common/parallel.dart';
import '../engine/engine.dart';
import 'prefetch.dart';
import 'webdav_client.dart';

/// 单个文件的扫描结果（[report] 与 [error] 二选一）。
class ScanItem {
  const ScanItem({
    required this.url,
    required this.path,
    required this.name,
    required this.size,
    this.report,
    this.error,
  });

  final String url;

  /// 相对扫描根目录的展示路径（解码后），如 `movies/a.mp4`。
  final String path;
  final String name;
  final int size;
  final InspectReport? report;
  final String? error;

  bool get needsFix => report?.health == Mp4Health.needsReinterleave;

  @override
  String toString() => 'ScanItem($path: ${report?.health.name ?? error})';
}

/// 递归扫描 WebDAV 目录中的视频文件并逐个做 MP4 健康检测。
///
/// 检测优先走 Range 分段读取（只取顶层盒头与 moov，速度快、流量小）；
/// 服务器不支持 Range 时自动回退为"完整下载到本地临时文件再检测"。
class WebDavScanner {
  WebDavScanner(
    this.client, {
    this.threshold = Mp4Inspect.defaultInterleaveThreshold,
    this.thresholdSeconds = Mp4Inspect.defaultInterleaveThresholdSeconds,
    this.maxDirs = 20000,
    this.maxFiles = 100000,
    this.fallbackDownloadLimit = 2 << 30,
    this.maxMoovBytes = 64 << 20,
    this.fileConcurrency = 4,
    this.dirConcurrency = 3,
  });

  final WebDavClient client;
  final int threshold;

  /// 时间错位阈值（秒）；与字节阈值任一满足即判「需重排」。
  final double thresholdSeconds;
  final int maxDirs;
  final int maxFiles;
  final int fallbackDownloadLimit;

  /// 单个 moov 的预取上限。
  ///
  /// 并行扫描时内存里同时有「并发数 × 上限」的预取数据：4 路 × 256MB
  /// 峰值可达 1GB。正常 4K 长片的 moov 通常只有几 MB~几十 MB，64MB 足够；
  /// 超过就明确提示下载到本地处理，而不是冒 OOM 的险。
  final int maxMoovBytes;

  /// 同时检测的文件数。
  ///
  /// 远程检测的耗时几乎全是「发一个 Range 请求 → 等往返 → 解析 → 再发」。
  /// 串行时链路有一半时间在空转；同时跑 3~4 个文件就能把等待叠起来。
  /// 同一时间对服务器只有几个小请求，负担远小于整档下载。
  final int fileConcurrency;

  /// 同时列举的目录数。
  ///
  /// 「一目录一两个文件」的素材库（按剧集 / 日期分目录很常见）里，
  /// PROPFIND 的往返才是大头。3 路并发对家用 NAS 很温和。
  final int dirConcurrency;

  /// 参与检测的扩展名。
  static const Set<String> videoExtensions = {'mp4', 'm4v', 'mov'};

  static const Set<String> _skipDirs = {
    '@eadir',
    '#recycle',
    '.trash',
    'system volume information',
    r'$recycle.bin',
  };

  /// Range 支持探测结果（首个文件时确定一次）。
  bool? _rangeSupport;

  /// 降级下载的临时文件序号。
  ///
  /// 并行扫描时会有多个文件同时走「整档下载」回退；只按时间戳命名在
  /// 时钟精度粗的平台（1ms）上可能撞名 —— 两个文件互相覆盖，检测结果就串了。
  static int _probeSeq = 0;

  /// 扫描 [rootUrl] 下的全部视频文件；每个文件完成检测后回调 [onFile]。
  ///
  /// [tempDir]：不支持 Range 时的本地临时目录（需可写）。
  Future<List<ScanItem>> scan(
    String rootUrl, {
    required Directory tempDir,
    void Function(ScanItem item)? onFile,
    void Function(String path, int files)? onDirectory,
    bool Function()? isCancelled,
  }) async {
    final results = <ScanItem>[];
    final visited = <String>{};
    var fileCount = 0;
    var stopped = false;

    // 文件是边遍历目录边发现的：用滑动窗口把「已发现但还没检测完」的文件
    // 控制在 fileConcurrency 个以内（窗口满时等一个完成，再继续遍历）。
    final window = ParallelWindow(fileConcurrency);
    // 目录列举同样要并行：子目录一发现就投递，谁先列完谁先产出文件。
    // 这里必须用「投递不阻塞」的 TaskPool —— 目录任务会继续投递子目录，
    // 用滑动窗口会等待「包括自己在内」的窗口腾位（死锁）。
    final dirs = TaskPool(dirConcurrency);

    bool cancelled() => stopped || (isCancelled?.call() ?? false);

    void report(ScanItem item) {
      results.add(item);
      onFile?.call(item);
    }

    Future<void> inspectLater(DavEntry entry, String relPath) {
      return window.submit(() async {
        if (cancelled()) return;
        final item = await _inspectFile(entry, relPath, tempDir, isCancelled);
        // 取消 / 撞上限之后才完成的检测：不再往界面塞条目（否则列表里会
        // 多出一堆「已取消」的错误行）
        if (cancelled()) return;
        report(item);
      });
    }

    Future<void> walk(String dirUrl, String relPath) async {
      if (cancelled()) return;
      if (!visited.add(dirUrl)) return;
      if (visited.length > maxDirs) return;

      final List<DavEntry> entries;
      try {
        entries = await client.list(dirUrl);
      } catch (e) {
        if (cancelled()) return;
        final name = relPath.isNotEmpty ? relPath.split('/').last : '';
        report(ScanItem(
          url: dirUrl,
          path: relPath.isEmpty ? '/' : relPath,
          name: name,
          size: -1,
          error: '读取目录失败：${errorMessage(e)}',
        ));
        return;
      }

      var filesHere = 0;
      for (final entry in entries) {
        if (cancelled()) return;
        if (entry.isDirectory) {
          if (entry.url.replaceAll(RegExp(r'/+$'), '') ==
              dirUrl.replaceAll(RegExp(r'/+$'), '')) {
            continue; // 目录自身
          }
          if (_skipDirs.contains(entry.name.toLowerCase())) continue;
          final childRel =
              relPath.isEmpty ? entry.name : '$relPath/${entry.name}';
          // 子目录一发现就投递（TaskPool 只入队，不阻塞当前遍历）
          dirs.add(() => walk(entry.url, childRel));
          continue;
        }
        final dot = entry.name.lastIndexOf('.');
        final ext = dot >= 0 ? entry.name.substring(dot + 1).toLowerCase() : '';
        if (!videoExtensions.contains(ext)) continue;
        fileCount++;
        if (fileCount > maxFiles) {
          stopped = true;
          return;
        }
        filesHere++;
        final childRel = relPath.isEmpty ? entry.name : '$relPath/${entry.name}';
        // 文件窗口满时这里会等一个检测完成，再继续遍历下一个目录
        await inspectLater(entry, childRel);
      }
      if (!cancelled()) {
        onDirectory?.call(relPath.isEmpty ? '/' : relPath, filesHere);
      }
    }

    dirs.add(() => walk(client.ensureTrailingSlash(rootUrl), ''));
    // 先等目录遍历收尾（它会不断投递文件检测），再等所有在跑的检测 ——
    // 不能让它们在本方法返回之后才回调 onFile。
    // finally：目录遍历即使因意外报错，也要把已投递的文件检测收干净。
    try {
      await dirs.idle();
    } finally {
      await window.drain();
    }
    return results;
  }

  /// 重新检测单个文件（界面「重做」用）：按原 URL / 大小再做一次同样的检测。
  Future<ScanItem> inspectSingle(
    ScanItem item, {
    required Directory tempDir,
    bool Function()? isCancelled,
  }) {
    final entry = DavEntry(
      url: item.url,
      name: item.name,
      isDirectory: false,
      size: item.size,
    );
    return _inspectFile(entry, item.path, tempDir, isCancelled);
  }

  Future<ScanItem> _inspectFile(
    DavEntry entry,
    String relPath,
    Directory tempDir,
    bool Function()? isCancelled,
  ) async {
    try {
      final report = await _inspect(entry, tempDir, isCancelled);
      return ScanItem(
        url: entry.url,
        path: relPath,
        name: entry.name,
        size: entry.size,
        report: report,
      );
    } on RangeNotSupportedException {
      _rangeSupport = false;
      try {
        return ScanItem(
          url: entry.url,
          path: relPath,
          name: entry.name,
          size: entry.size,
          report: await _inspectViaDownload(
            entry,
            tempDir,
            isCancelled: isCancelled,
          ),
        );
      } catch (e2) {
        return ScanItem(
          url: entry.url,
          path: relPath,
          name: entry.name,
          size: entry.size,
          error: (isCancelled?.call() ?? false) ? '已取消' : '检测失败：${errorMessage(e2)}',
        );
      }
    } catch (e) {
      return ScanItem(
        url: entry.url,
        path: relPath,
        name: entry.name,
        size: entry.size,
        error: (isCancelled?.call() ?? false) ? '已取消' : '检测失败：${errorMessage(e)}',
      );
    }
  }

  Future<InspectReport> _inspect(
    DavEntry entry,
    Directory tempDir,
    bool Function()? isCancelled,
  ) async {
    // 服务器未返回 getcontentlength 时先补一次 stat（否则按 0 处理会误报"损坏"）
    var size = entry.size;
    if (size < 0) {
      final st = await client.stat(entry.url);
      size = st?.size ?? -1;
    }
    if (!await _rangeOk(entry)) {
      return _inspectViaDownload(entry, tempDir, isCancelled: isCancelled);
    }
    if (size < 0) {
      // 仍未知大小：Range 预取无法进行，回退整档下载
      return _inspectViaDownload(entry, tempDir, isCancelled: isCancelled);
    }
    final input = await prefetchForInspect(
      client,
      entry.url,
      fileSize: size,
      maxMoovBytes: maxMoovBytes,
      isCancelled: isCancelled,
    );
    try {
      return Mp4Inspect.inspect(
        input,
        interleaveThresholdBytes: threshold,
        interleaveThresholdSeconds: thresholdSeconds,
      );
    } finally {
      input.close();
    }
  }

  Future<bool> _rangeOk(DavEntry entry) async {
    final cached = _rangeSupport;
    if (cached != null) return cached;
    final ok = await client.supportsRange(entry.url);
    _rangeSupport = ok;
    return ok;
  }

  /// 整档下载降级的并发闸门：服务器不支持 Range 时，最坏会退化成整档
  /// 下载；同时开 4 个 2GB 文件会把临时空间瞬间打满。限制 2 路。
  final Semaphore _fallbackGate = Semaphore(2);

  Future<InspectReport> _inspectViaDownload(
    DavEntry entry,
    Directory tempDir, {
    bool Function()? isCancelled,
  }) {
    // 等闸门之前先看一眼：取消后排队中的任务不必再发起整档下载
    if (isCancelled?.call() ?? false) {
      return Future.error(WebDavException('已取消'));
    }
    return _fallbackGate.run(
      () => _downloadAndInspect(entry, tempDir, isCancelled: isCancelled),
    );
  }

  Future<InspectReport> _downloadAndInspect(
    DavEntry entry,
    Directory tempDir, {
    bool Function()? isCancelled,
  }) async {
    if (entry.size > fallbackDownloadLimit) {
      throw WebDavException(
        '服务器不支持分段读取，且文件过大（${formatBytes(entry.size)}），已跳过',
      );
    }
    final tmp = File(
      '${tempDir.path}/probe-${DateTime.now().microsecondsSinceEpoch}'
      '-${_probeSeq++}.mp4',
    );
    try {
      await client.download(entry.url, tmp, isCancelled: isCancelled);
      final input = FileSeekableInput(tmp);
      try {
        return Mp4Inspect.inspect(
        input,
        interleaveThresholdBytes: threshold,
        interleaveThresholdSeconds: thresholdSeconds,
      );
      } finally {
        input.close();
      }
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }
}
