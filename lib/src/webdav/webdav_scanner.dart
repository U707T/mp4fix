import 'dart:io';

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
    this.maxDirs = 20000,
    this.maxFiles = 100000,
    this.fallbackDownloadLimit = 2 << 30,
    this.maxMoovBytes = 256 << 20,
  });

  final WebDavClient client;
  final int threshold;
  final int maxDirs;
  final int maxFiles;
  final int fallbackDownloadLimit;
  final int maxMoovBytes;

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
    final stack = <({String url, String relPath})>[
      (url: client.ensureTrailingSlash(rootUrl), relPath: ''),
    ];
    var fileCount = 0;

    void report(ScanItem item) {
      results.add(item);
      onFile?.call(item);
    }

    while (stack.isNotEmpty) {
      if (isCancelled?.call() ?? false) return results;
      final current = stack.removeLast();
      final dirUrl = current.url;
      final relPath = current.relPath;
      if (!visited.add(dirUrl)) continue;
      if (visited.length > maxDirs) return results;

      final List<DavEntry> entries;
      try {
        entries = await client.list(dirUrl);
      } catch (e) {
        if (isCancelled?.call() ?? false) return results;
        final name = relPath.isNotEmpty ? relPath.split('/').last : '';
        report(ScanItem(
          url: dirUrl,
          path: relPath.isEmpty ? '/' : relPath,
          name: name,
          size: -1,
          error: '读取目录失败：${errorMessage(e)}',
        ));
        continue;
      }

      var filesHere = 0;
      for (final entry in entries) {
        if (isCancelled?.call() ?? false) return results;
        if (entry.isDirectory) {
          if (entry.url.replaceAll(RegExp(r'/+$'), '') ==
              dirUrl.replaceAll(RegExp(r'/+$'), '')) {
            continue; // 目录自身
          }
          if (_skipDirs.contains(entry.name.toLowerCase())) continue;
          final childRel =
              relPath.isEmpty ? entry.name : '$relPath/${entry.name}';
          stack.add((url: entry.url, relPath: childRel));
          continue;
        }
        final dot = entry.name.lastIndexOf('.');
        final ext = dot >= 0 ? entry.name.substring(dot + 1).toLowerCase() : '';
        if (!videoExtensions.contains(ext)) continue;
        fileCount++;
        if (fileCount > maxFiles) return results;
        filesHere++;
        final childRel = relPath.isEmpty ? entry.name : '$relPath/${entry.name}';
        report(await _inspectFile(entry, childRel, tempDir, isCancelled));
      }
      onDirectory?.call(relPath.isEmpty ? '/' : relPath, filesHere);
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
          report: await _inspectViaDownload(entry, tempDir),
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
      return _inspectViaDownload(entry, tempDir);
    }
    if (size < 0) {
      // 仍未知大小：Range 预取无法进行，回退整档下载
      return _inspectViaDownload(entry, tempDir);
    }
    final input = await prefetchForInspect(
      client,
      entry.url,
      fileSize: size,
      maxMoovBytes: maxMoovBytes,
      isCancelled: isCancelled,
    );
    try {
      return Mp4Inspect.inspect(input, interleaveThresholdBytes: threshold);
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

  Future<InspectReport> _inspectViaDownload(
    DavEntry entry,
    Directory tempDir,
  ) async {
    if (entry.size > fallbackDownloadLimit) {
      throw WebDavException(
        '服务器不支持分段读取，且文件过大（${formatBytes(entry.size)}），已跳过',
      );
    }
    final tmp = File(
      '${tempDir.path}/probe-${DateTime.now().microsecondsSinceEpoch}.mp4',
    );
    try {
      await client.download(entry.url, tmp);
      final input = FileSeekableInput(tmp);
      try {
        return Mp4Inspect.inspect(input, interleaveThresholdBytes: threshold);
      } finally {
        input.close();
      }
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }
}
