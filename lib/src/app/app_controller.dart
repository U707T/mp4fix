import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';

import '../engine/engine.dart';
import '../platform/android_platform.dart';
import '../webdav/webdav.dart';
import 'engine_tasks.dart';
import 'models.dart';
import 'output_target.dart';
import 'settings_store.dart';

/// 应用状态：设置 + 任务队列 + 三个功能入口的流程编排。
class AppController extends ChangeNotifier {
  AppSettings settings = AppSettings();
  final List<FixJob> jobs = [];

  bool initializing = true;
  JobSource? _runningSource;
  bool _cancelRequested = false;
  final Map<String, ScanItem> _webDavItems = {};

  /// 本地文件的临时目录（缓存）。
  Directory? _cacheDir;

  bool get running => _runningSource != null;

  JobSource? get runningSource => _runningSource;

  /// 正在后台跑的那次修复（取消时立即中断）。
  RepairTask? _activeRepair;

  int _lastNotifyAt = 0;

  /// 进度类更新最多 10 次/秒（避免 UI 重建风暴；状态变更仍即时通知）。
  void _notifyThrottled() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastNotifyAt < 100) return;
    _lastNotifyAt = now;
    notifyListeners();
  }

  /// 是否有可修复的任务。
  bool hasFixable(JobSource source) =>
      jobs.any((j) => j.source == source && j.status.fixable);

  List<FixJob> jobsOf(JobSource source) =>
      jobs.where((j) => j.source == source).toList(growable: false);

  // ---------------------------------------------------------------- 初始化

  Future<void> init() async {
    settings = await SettingsStore.load() ?? AppSettings();
    initializing = false;
    notifyListeners();
  }

  void updateSettings(void Function(AppSettings s) mutate) {
    mutate(settings);
    notifyListeners();
    unawaited(SettingsStore.save(settings));
  }

  Future<Directory> _cache() async {
    final cached = _cacheDir;
    if (cached != null) return cached;
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/work');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _cacheDir = dir;
  }

  // ---------------------------------------------------------------- 任务工具

  int _seq = 0;

  FixJob _newJob({
    required JobSource source,
    required String name,
    required String displayPath,
    required int size,
    String? localPath,
    String? webDavUrl,
  }) {
    final job = FixJob(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
      source: source,
      name: name,
      displayPath: displayPath,
      size: size,
      localPath: localPath,
      webDavUrl: webDavUrl,
    );
    jobs.add(job);
    notifyListeners();
    return job;
  }

  void clearJobs(JobSource source) {
    if (_runningSource == source) return;
    jobs.removeWhere((j) => j.source == source);
    _webDavItems.removeWhere((k, _) => !jobs.any((j) => j.id == k));
    notifyListeners();
  }

  void removeJob(FixJob job) {
    if (job.busy || _runningSource == job.source) return;
    jobs.remove(job);
    _webDavItems.remove(job.id);
    notifyListeners();
  }

  /// 请求停止当前批处理（同时立即中断后台修复）。
  void requestCancel() {
    if (!running) return;
    _cancelRequested = true;
    _activeRepair?.cancel();
    _activeRepair = null;
    notifyListeners();
  }

  void _setRunning(JobSource? source) {
    _runningSource = source;
    _cancelRequested = false;
    notifyListeners();
  }

  String _message(Object e) => errorMessage(e);

  /// 供 [WebDavFixer] 使用的修复执行器：在后台 Isolate 中跑引擎，避免卡住界面。
  Future<void> _isolateRepair({
    required File input,
    required File output,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final task = await RepairTask.start(
      inputPath: input.path,
      outputPath: output.path,
      onProgress: onProgress,
    );
    _activeRepair = task;
    try {
      await task.done;
    } catch (_) {
      if (output.existsSync()) output.deleteSync();
      rethrow;
    } finally {
      if (identical(_activeRepair, task)) _activeRepair = null;
    }
  }

  // ---------------------------------------------------------------- 输出目标

  Future<OutputTarget> outputTarget() async {
    final tree = settings.outputTreeUri;
    if (tree != null && tree.isNotEmpty && AndroidPlatform.isSupported) {
      return SafOutputTarget(tree, displayName: _treeName(tree));
    }
    final dirPath = settings.outputDirPath;
    if (dirPath != null && dirPath.isNotEmpty) {
      return DirectoryOutputTarget(Directory(dirPath));
    }
    return defaultOutputTarget();
  }

  String _treeName(String treeUri) {
    final segments = Uri.tryParse(treeUri)?.pathSegments ?? const <String>[];
    if (segments.isEmpty) return treeUri;
    final seg = segments.last;
    return seg.isEmpty ? treeUri : Uri.decodeComponent(seg);
  }

  /// 当前输出目标的展示文案（同步，供界面即时显示）。
  String get outputDescription {
    final tree = settings.outputTreeUri;
    if (tree != null && tree.isNotEmpty && AndroidPlatform.isSupported) {
      return '输出：${_treeName(tree)}';
    }
    final dir = settings.outputDirPath;
    if (dir != null && dir.isNotEmpty) return '输出：$dir';
    return '输出：应用文档目录/MP4Fix（默认）';
  }

  /// 当前阈值 / 可优化设置的展示文案。
  String get thresholdDescription =>
      '阈值 ${settings.thresholdMb} MB'
      '${settings.includeOptimizable ? ' · 含可优化' : ''}';

  /// 文件夹扫描输入目录的展示文案。
  String get scanInputDescription {
    if (AndroidPlatform.isSupported) {
      final tree = settings.scanInputTreeUri;
      if (tree == null || tree.isEmpty) return '未选择输入文件夹';
      return _treeName(tree);
    }
    final dir = settings.scanInputDirPath;
    if (dir == null || dir.isEmpty) return '未选择输入文件夹';
    return dir;
  }

  /// 选择输出文件夹（Android 走 SAF，桌面走目录选择）。
  Future<void> pickOutputFolder() async {
    if (AndroidPlatform.isSupported) {
      final dir = await SafUtil().pickDirectory(
        writePermission: true,
        persistablePermission: true,
      );
      if (dir != null) {
        updateSettings((s) => s.outputTreeUri = dir.uri);
      }
      return;
    }
    final path = await FilePicker.getDirectoryPath();
    if (path != null) {
      updateSettings((s) => s.outputDirPath = path);
    }
  }

  /// 选择"文件夹批量检测"的输入目录。
  Future<void> pickScanInputFolder() async {
    if (AndroidPlatform.isSupported) {
      final dir = await SafUtil().pickDirectory();
      if (dir != null) {
        updateSettings((s) => s.scanInputTreeUri = dir.uri);
      }
      return;
    }
    final path = await FilePicker.getDirectoryPath();
    if (path != null) {
      updateSettings((s) => s.scanInputDirPath = path);
    }
  }

  // ---------------------------------------------------------------- 本地文件

  /// 选择本地视频（多选）。
  Future<void> pickLocalFiles() async {
    if (running) return;
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['mp4', 'm4v', 'mov'],
    );
    if (files.isEmpty) return;

    final created = <FixJob>[];
    for (final f in files) {
      var path = f.path;
      // Android：content:// 输入（非本地路径）先复制到应用缓存
      if (path == null && f.uri.scheme == 'content' && AndroidPlatform.isSupported) {
        path = await AndroidPlatform.copyToCache(
          uri: f.uri.toString(),
          name: f.name,
        );
      }
      if (path == null) continue;
      created.add(_newJob(
        source: JobSource.local,
        name: f.name,
        displayPath: f.name,
        size: f.lengthSync() ?? -1,
        localPath: path,
      ));
    }
    if (created.isEmpty) return;
    unawaited(_inspectLocalJobs(created));
  }

  Future<void> _inspectLocalJobs(List<FixJob> targets) async {
    _setRunning(targets.first.source);
    for (final job in targets) {
      if (_cancelRequested) break;
      final path = job.localPath;
      if (path == null) continue;
      job.status = JobStatus.inspecting;
      job.message = '读取文件头与 moov…';
      job.progress = 0;
      notifyListeners();
      try {
        final report = await inspectFileInIsolate(
          path,
          thresholdBytes: settings.thresholdBytes,
        );
        _applyReport(job, report);
      } catch (e) {
        job.status = JobStatus.error;
        job.message = _message(e);
      }
      notifyListeners();
    }
    _setRunning(null);
  }

  void _applyReport(FixJob job, InspectReport report) {
    job.report = report;
    job.message = report.detail;
    job.status = switch (report.health) {
      Mp4Health.ok => JobStatus.ok,
      Mp4Health.needsReinterleave => JobStatus.needsFix,
      Mp4Health.optimizable => JobStatus.optimizable,
      Mp4Health.corrupt => JobStatus.corrupt,
      Mp4Health.unsupported => JobStatus.unsupported,
    };
  }

  // ---------------------------------------------------------------- 文件夹

  /// 扫描输入目录（可选修复）。Android 走 SAF 递归 + 缓存复制；桌面直接读目录。
  Future<void> scanFolder({bool fixAfterScan = false}) async {
    if (running) return;
    final targets = <FixJob>[];
    try {
      await _scanFolderInner(targets);
    } finally {
      // 无论成功 / 抛错 / 取消，都必须复位运行状态
      if (_runningSource == JobSource.folder) _setRunning(null);
    }
    if (fixAfterScan && !_cancelRequested) {
      await fixJobs(JobSource.folder, targets);
    }
  }

  /// scanFolder 的实际工作（外层负责运行状态复位）。
  Future<void> _scanFolderInner(List<FixJob> targets) async {
    if (AndroidPlatform.isSupported) {
      final tree = settings.scanInputTreeUri;
      if (tree == null || tree.isEmpty) {
        throw StateError('请先选择输入文件夹');
      }
      _setRunning(JobSource.folder);
      final entries = await _listTreeVideos(tree);
      for (final e in entries) {
        if (_cancelRequested) break;
        final job = _newJob(
          source: JobSource.folder,
          name: e.name,
          displayPath: e.path,
          size: e.size,
        );
        targets.add(job);
        job.status = JobStatus.inspecting;
        job.message = '复制的缓存中…';
        notifyListeners();
        try {
          final local = await AndroidPlatform.copyToCache(
            uri: e.uri,
            name: e.name,
          );
          job.localPath = local;
          final report = await inspectFileInIsolate(
            local,
            thresholdBytes: settings.thresholdBytes,
          );
          _applyReport(job, report);
        } catch (err) {
          job.status = JobStatus.error;
          job.message = _message(err);
        }
        notifyListeners();
      }
    } else {
      final dirPath = settings.scanInputDirPath;
      if (dirPath == null || dirPath.isEmpty) {
        throw StateError('请先选择输入文件夹');
      }
      _setRunning(JobSource.folder);
      final dir = Directory(dirPath);
      final files = dir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) => _isVideoName(f.path.split('/').last))
          .toList();
      for (final f in files) {
        if (_cancelRequested) break;
        final name = f.path.split('/').last;
        final rel = f.path.substring(dir.path.length).replaceFirst(RegExp(r'^/+'), '');
        final job = _newJob(
          source: JobSource.folder,
          name: name,
          displayPath: rel,
          size: f.lengthSync(),
          localPath: f.path,
        );
        targets.add(job);
        job.status = JobStatus.inspecting;
        notifyListeners();
        try {
          final report = await inspectFileInIsolate(
            f.path,
            thresholdBytes: settings.thresholdBytes,
          );
          _applyReport(job, report);
        } catch (err) {
          job.status = JobStatus.error;
          job.message = _message(err);
        }
        notifyListeners();
      }
    }

  }


  static bool _isVideoName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = name.substring(dot + 1).toLowerCase();
    return ext == 'mp4' || ext == 'm4v' || ext == 'mov';
  }

  /// SAF 树递归列举视频（返回 uri / 展示路径 / 名称 / 大小）。
  Future<List<({String uri, String path, String name, int size})>>
      _listTreeVideos(String treeUri) async {
    final saf = SafUtil();
    final out = <({String uri, String path, String name, int size})>[];
    final stack = <({String uri, String rel})>[(uri: treeUri, rel: '')];
    final visited = <String>{};
    const skip = {
      '@eadir',
      '#recycle',
      '.trash',
      'system volume information',
      r'$recycle.bin',
      'android',
    };

    while (stack.isNotEmpty && !_cancelRequested) {
      final current = stack.removeLast();
      if (!visited.add(current.uri)) continue;
      if (visited.length > 20000 || out.length > 200000) break;
      List<SafDocumentFile> children;
      try {
        children = await saf.list(current.uri);
      } catch (_) {
        continue;
      }
      for (final child in children) {
        if (_cancelRequested) break;
        final name = child.name;
        if (name.isEmpty) continue;
        final rel = current.rel.isEmpty ? name : '${current.rel}/$name';
        if (child.isDir) {
          if (skip.contains(name.toLowerCase())) continue;
          stack.add((uri: child.uri, rel: rel));
        } else if (_isVideoName(name)) {
          out.add((uri: child.uri, path: rel, name: name, size: child.length));
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- WebDAV

  WebDavClient _webDavClient() {
    final cfg = settings.webdav;
    if (cfg.host.trim().isEmpty) throw StateError('请先填写主机地址');
    return WebDavClient(
      cfg.url,
      username: cfg.user.trim(),
      password: webDavPassword,
      allowInsecureTls: cfg.insecure,
    );
  }

  /// 密码只保存在内存（不落盘）。
  String webDavPassword = '';

  /// 测试连接（返回根目录条目统计）。
  Future<String> testWebDavConnection() async {
    final client = _webDavClient();
    try {
      await _ensureLocalNetworkPermission();
      final entries = await client.list(client.root);
      final dirs = entries.where((e) => e.isDirectory).length;
      final files = entries.length - dirs;
      return '连接成功：${client.root}（根目录 $dirs 个目录 · $files 个文件）';
    } finally {
      client.close();
    }
  }

  /// 确保 Android 17 的「本地网络」权限（访问局域网必需）。
  Future<void> _ensureLocalNetworkPermission() async {
    if (!AndroidPlatform.isSupported) return;
    try {
      final status = await Permission.accessLocalNetwork.status;
      if (!status.isGranted) {
        await Permission.accessLocalNetwork.request();
      }
    } catch (_) {
      // 老系统没有该权限（permission_handler 会返回 granted/不支持的组合）
    }
  }

  /// 扫描 WebDAV 目录（可选修复）。
  Future<void> scanWebDav({bool fixAfterScan = false, bool uploadCopies = true}) async {
    if (running) return;
    final client = _webDavClient();
    _setRunning(JobSource.webdav);
    final cache = await _cache();
    try {
      await _ensureLocalNetworkPermission();
      final scanner = WebDavScanner(client, threshold: settings.thresholdBytes);
      final items = await scanner.scan(
        client.root,
        tempDir: cache,
        onFile: (item) {
          final job = _newJob(
            source: JobSource.webdav,
            name: item.name,
            displayPath: item.path,
            size: item.size,
            webDavUrl: item.url,
          );
          if (item.report != null) {
            _applyReport(job, item.report!);
          } else {
            job.status = JobStatus.error;
            job.message = item.error ?? '检测失败';
          }
          _webDavItems[job.id] = item;
          notifyListeners();
        },
        isCancelled: () => _cancelRequested,
      );
      debugPrint('WebDAV 扫描完成：${items.length} 个视频');
    } finally {
      client.close();
      _setRunning(null);
    }
    if (fixAfterScan && !_cancelRequested) {
      await fixWebDavJobs(uploadCopies: uploadCopies);
    }
  }

  Future<void> fixWebDavJobs({required bool uploadCopies}) async {
    if (running) return;
    final client = _webDavClient();
    _setRunning(JobSource.webdav);
    final cache = await _cache();
    final fixer = WebDavFixer(client, cacheDir: cache, repair: _isolateRepair);
    try {
      await _ensureLocalNetworkPermission();
      final targets = jobs
          .where((j) => j.source == JobSource.webdav && j.status.fixable)
          .toList();
      final output = uploadCopies ? null : await outputTarget();
      for (final job in targets) {
        if (_cancelRequested) break;
        final item = _webDavItems[job.id];
        if (item == null) continue;
        job.status = JobStatus.fixing;
        job.progress = 0;
        job.message = uploadCopies ? '准备上传副本…' : '准备保存到本地…';
        notifyListeners();

        if (uploadCopies) {
          final result = await fixer.fix(
            item,
            onPhase: (phase, progress) {
              job.message = '$phase ${(progress * 100).round()}%';
              job.progress = progress;
              _notifyThrottled();
            },
            isCancelled: () => _cancelRequested,
          );
          _applyFixResult(job, result, uploaded: true);
        } else {
          final tmp = File('${cache.path}/${job.id}-fixed.mp4');
          try {
            final result = await fixer.fixToFile(
              item,
              tmp,
              onPhase: (phase, progress) {
                job.message = '$phase ${(progress * 100).round()}%';
                job.progress = progress;
                _notifyThrottled();
              },
              isCancelled: () => _cancelRequested,
            );
            if (result.ok) {
              final saved = await output!.save(tmp, job.name);
              job.outputPath = saved;
              job.status = JobStatus.saved;
              job.message = '已保存：$saved';
            }
            _applyFixResult(job, result, uploaded: false);
          } finally {
            if (tmp.existsSync()) tmp.deleteSync();
          }
        }
        job.progress = 0;
        notifyListeners();
      }
    } finally {
      client.close();
      _setRunning(null);
    }
  }

  void _applyFixResult(FixJob job, FixResult result, {required bool uploaded}) {
    if (result.cancelled) {
      job.status = JobStatus.cancelled;
      job.message = '已取消';
    } else if (result.ok) {
      job.status = uploaded ? JobStatus.uploaded : JobStatus.saved;
      job.outputPath = result.remoteName ?? job.outputPath;
      job.message = uploaded
          ? '已上传副本：${result.remoteName}（原文件未改动）'
          : job.message;
    } else {
      job.status = JobStatus.failed;
      job.message = '失败：${result.message}';
    }
  }

  // ---------------------------------------------------------------- 批量修复

  /// 修复某来源下所有"可修复"的任务。
  Future<void> fixJobs(JobSource source, [List<FixJob>? only]) async {
    if (running) return;
    final targets = only ??
        jobs.where((j) => j.source == source && j.status.fixable).toList();
    if (targets.isEmpty) return;
    _setRunning(source);
    final output = await outputTarget();
    final cache = await _cache();
    try {
      for (final job in targets) {
        if (_cancelRequested) break;
        final inputPath = job.localPath;
        if (inputPath == null) {
          job.status = JobStatus.failed;
          job.message = '缺少本地文件';
          notifyListeners();
          continue;
        }
        job.status = JobStatus.fixing;
        job.progress = 0;
        job.message = '修复中…';
        notifyListeners();

        final base = job.name.contains('.')
            ? job.name.substring(0, job.name.lastIndexOf('.'))
            : job.name;
        final outName = '$base.mp4';
        final direct = output.directDirectory;
        final tmp = direct == null
            ? File('${cache.path}/${job.id}-$outName')
            : File('${direct.path}/$outName');

        RepairTask? task;
        try {
          task = await RepairTask.start(
            inputPath: inputPath,
            outputPath: tmp.path,
            onProgress: (done, total) {
              if (total > 0) {
                job.progress = done / total;
                job.message = '修复中 ${(job.progress * 100).round()}%';
                _notifyThrottled();
              }
            },
          );
          await task.done;
          if (_cancelRequested) {
            job.status = JobStatus.cancelled;
            job.message = '已取消';
          } else {
            if (direct == null) {
              final saved = await output.save(tmp, outName);
              job.outputPath = saved;
            } else {
              job.outputPath = outName;
            }
            job.status = JobStatus.saved;
            job.message = '已保存：${job.outputPath}';
          }
        } catch (e) {
          job.status = (e is RepairCancelledException || task?.cancelled == true)
              ? JobStatus.cancelled
              : JobStatus.failed;
          job.message = job.status == JobStatus.cancelled ? '已取消' : _message(e);
        } finally {
          if (direct == null && tmp.existsSync()) tmp.deleteSync();
        }
        job.progress = 0;
        notifyListeners();
      }
    } finally {
      _setRunning(null);
    }
  }

  /// 清理本地任务留下的缓存副本。
  Future<void> cleanCache() async {
    final cache = await _cache();
    if (cache.existsSync()) {
      for (final f in cache.listSync()) {
        try {
          f.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
    notifyListeners();
  }
}
