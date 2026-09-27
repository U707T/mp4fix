import 'dart:async';
import 'dart:io';
import 'dart:isolate';

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

  /// 最近一次操作的补充提示（如"跳过了 N 个无法读取的文件夹"）。
  String? lastNotice;

  /// 批量进度（界面顶部的总进度条用）。
  int batchDone = 0;
  int batchTotal = 0;

  void _setBatch(int total) {
    batchTotal = total;
    batchDone = 0;
    notifyListeners();
  }

  void _tickBatch(int done) {
    batchDone = done;
    notifyListeners();
  }

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
    // 恢复「记住密码」时保存的密码
    if (settings.rememberWebDavPassword && settings.webDavPassword.isNotEmpty) {
      webDavPassword = settings.webDavPassword;
    }
    // 桌面：提前建好默认输出目录，避免首次修复因"目录不存在"失败
    if (!AndroidPlatform.isSupported) {
      try {
        await defaultOutputTarget();
      } catch (_) {
        // 忽略：真正写入时会给出明确错误
      }
    }
    initializing = false;
    notifyListeners();
  }

  /// 收集诊断信息（路径 / 是否存在 / 平台），便于远程排查。
  Future<String> collectDiagnostics() async {
    final lines = <String>[
      'MP4Fix 诊断信息',
      '平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      '设置: 阈值 ${settings.thresholdMb}MB · 含可优化=${settings.includeOptimizable}',
      '输出目标: $outputDescription',
    ];
    if (AndroidPlatform.isSupported) {
      lines.add('输出(SAF): ${settings.outputTreeUri ?? "（未选择 → 默认 下载/MP4Fix）"}');
    } else {
      final dir = settings.outputDirPath;
      lines.add('输出目录: ${dir ?? "（未选择 → 默认 应用文档目录/MP4Fix）"}');
      if (dir != null) lines.add('输出目录存在: ${Directory(dir).existsSync()}');
      final scan = settings.scanInputDirPath;
      lines.add('输入目录: ${scan ?? "-"}');
      if (scan != null) lines.add('输入目录存在: ${Directory(scan).existsSync()}');
    }
    try {
      final docs = await getApplicationDocumentsDirectory();
      lines.add('应用文档目录: ${docs.path}（存在: ${docs.existsSync()}）');
      final tmp = await getTemporaryDirectory();
      lines.add('临时目录: ${tmp.path}（存在: ${tmp.existsSync()}）');
    } catch (e) {
      lines.add('目录查询失败: ${describeError(e)}');
    }
    lines.add('临时缓存: ${(_cacheDir?.path) ?? "（未初始化）"}');
    return lines.join('\n');
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

  /// 清空某来源的任务；被移除的内容会暂存，供 [undoClear] 撤销（界面用 SnackBar 撤销，
  /// 不再弹确认框——少一步且不丢结果）。
  ({List<FixJob> jobs, Map<String, ScanItem> items})? _cleared;

  void clearJobs(JobSource source) {
    if (_runningSource == source) return;
    final removedJobs = jobs.where((j) => j.source == source).toList();
    if (removedJobs.isEmpty) return;
    final removedItems = <String, ScanItem>{
      for (final j in removedJobs)
        if (_webDavItems.containsKey(j.id)) j.id: _webDavItems[j.id]!,
    };
    _cleared = (jobs: removedJobs, items: removedItems);
    jobs.removeWhere((j) => j.source == source);
    _webDavItems.removeWhere((k, _) => !jobs.any((j) => j.id == k));
    notifyListeners();
  }

  /// 撤销上一次「清空」。
  bool undoClear() {
    final snapshot = _cleared;
    if (snapshot == null) return false;
    _cleared = null;
    jobs.insertAll(0, snapshot.jobs);
    _webDavItems.addAll(snapshot.items);
    notifyListeners();
    return true;
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

  String _message(Object e) => describeError(e);

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
    // Android 默认落到公共「下载/MP4Fix」，避免产物藏在应用私有目录里找不到
    if (AndroidPlatform.isSupported) return const DownloadsOutputTarget();
    return defaultOutputTarget();
  }

  String _treeName(String treeUri) {
    final segments = Uri.tryParse(treeUri)?.pathSegments ?? const <String>[];
    if (segments.isEmpty) return treeUri;
    final seg = segments.last;
    return seg.isEmpty ? treeUri : Uri.decodeComponent(seg);
  }

  /// 文件夹任务的输出目标：**没选输出文件夹时就地覆盖输入文件夹**（少选一次目录）。
  Future<OutputTarget> folderOutputTarget() async {
    if (hasCustomOutput) return outputTarget();
    if (AndroidPlatform.isSupported) {
      final tree = settings.scanInputTreeUri;
      if (tree != null && tree.isNotEmpty) {
        return SafOutputTarget(tree, displayName: '${_treeName(tree)}（就地覆盖）');
      }
    } else {
      final dir = settings.scanInputDirPath;
      if (dir != null && dir.isNotEmpty && Directory(dir).existsSync()) {
        return DirectoryOutputTarget(Directory(dir));
      }
    }
    return outputTarget();
  }

  /// 文件夹页输出位置的展示文案。
  String get folderOutputDescription =>
      hasCustomOutput ? outputDescription : '未选择 → 就地覆盖输入文件夹（原文件会被替换）';

  /// 用户是否指定了输出文件夹（否则用默认位置）。
  bool get hasCustomOutput {
    final tree = settings.outputTreeUri;
    if (tree != null && tree.isNotEmpty && AndroidPlatform.isSupported) return true;
    final dir = settings.outputDirPath;
    return dir != null && dir.isNotEmpty;
  }

  /// 当前输出目标的展示文案（同步，供界面即时显示）。
  String get outputDescription {
    final tree = settings.outputTreeUri;
    if (tree != null && tree.isNotEmpty && AndroidPlatform.isSupported) {
      return '输出：${_treeName(tree)}';
    }
    final dir = settings.outputDirPath;
    if (dir != null && dir.isNotEmpty) return '输出：$dir';
    if (AndroidPlatform.isSupported) return '输出：下载/MP4Fix（默认）';
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
    lastNotice = null;
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
    if (path == null) return;
    final normalized = normalizePickedPath(path);
    updateSettings((s) => s.outputDirPath = normalized);
    if (!Directory(normalized).existsSync()) {
      lastNotice = '所选文件夹当前不可访问：$normalized';
      notifyListeners();
    }
  }

  /// 选择"文件夹批量检测"的输入目录。
  Future<void> pickScanInputFolder() async {
    lastNotice = null;
    if (AndroidPlatform.isSupported) {
      final dir = await SafUtil().pickDirectory();
      if (dir != null) {
        updateSettings((s) => s.scanInputTreeUri = dir.uri);
      }
      return;
    }
    final path = await FilePicker.getDirectoryPath();
    if (path == null) return;
    final normalized = normalizePickedPath(path);
    updateSettings((s) => s.scanInputDirPath = normalized);
    if (!Directory(normalized).existsSync()) {
      lastNotice = '所选文件夹当前不可访问：$normalized';
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 本地文件

  /// 选择本地视频（多选）。
  ///
  /// [fixAfterPick] 为真时：检测完自动进入修复（「添加并修复」按钮，一次点击走完）。
  Future<void> pickLocalFiles({bool fixAfterPick = false}) async {
    if (running) return;
    lastNotice = null;
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
      path = normalizePickedPath(path);
      created.add(_newJob(
        source: JobSource.local,
        name: f.name,
        displayPath: f.name,
        size: f.lengthSync() ?? -1,
        localPath: path,
      ));
    }
    if (created.isEmpty) return;
    await _inspectLocalJobs(created);
    if (fixAfterPick && !_cancelRequested) {
      await fixJobs(JobSource.local, created.where((j) => j.status.fixable).toList());
    }
  }

  Future<void> _inspectLocalJobs(List<FixJob> targets) async {
    _setRunning(targets.first.source);
    _setBatch(targets.length);
    for (var li = 0; li < targets.length; li++) {
      final job = targets[li];
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
      _tickBatch(li + 1);
    }
    _setRunning(null);
    batchDone = 0;
    batchTotal = 0;
    notifyListeners();
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
    lastNotice = null;
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
      // 目录列举放到后台 Isolate：网络盘 / 大目录下 listSync 会把界面卡死；
      // 且逐个目录容忍失败（Windows 的 System Volume Information / junction 会拒绝访问）
      final listing = await Isolate.run(() => listVideosSync(dirPath));
      _setBatch(listing.files.length);
      if (listing.skipped > 0) {
        lastNotice = '已跳过 ${listing.skipped} 个无法读取的文件夹（权限 / 系统目录）';
        notifyListeners();
      }
      for (var li = 0; li < listing.files.length; li++) {
        final f = listing.files[li];
        if (_cancelRequested) break;
        final job = _newJob(
          source: JobSource.folder,
          name: f.path.split(Platform.pathSeparator).last,
          displayPath: f.rel,
          size: f.size,
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
        _tickBatch(li + 1);
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

  /// 当前 WebDAV 密码：仅在勾选「记住密码」时写进本机设置文件。
  String webDavPassword = '';

  /// 更新密码输入（勾了「记住密码」就同步落盘，避免连一次都要重输）。
  void updateWebDavPassword(String value) {
    webDavPassword = value;
    if (settings.rememberWebDavPassword) {
      settings.webDavPassword = value;
      unawaited(SettingsStore.save(settings));
    }
  }

  /// 切换「记住密码」。
  void setRememberWebDavPassword(bool value) {
    settings.rememberWebDavPassword = value;
    settings.webDavPassword = value ? webDavPassword : '';
    unawaited(SettingsStore.save(settings));
    notifyListeners();
  }

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

  /// WebDAV 整批修复使用的模式（上传副本 / 保存到本地），供「重试」沿用。
  bool webDavUploadCopies = true;

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
    webDavUploadCopies = uploadCopies;
    if (fixAfterScan && !_cancelRequested) {
      await fixWebDavJobs(uploadCopies: uploadCopies);
    }
  }

  Future<void> fixWebDavJobs({bool? uploadCopies, List<FixJob>? only}) async {
    if (running) return;
    uploadCopies ??= webDavUploadCopies;
    webDavUploadCopies = uploadCopies;
    final client = _webDavClient();
    _setRunning(JobSource.webdav);
    final cache = await _cache();
    final fixer = WebDavFixer(client, cacheDir: cache, repair: _isolateRepair);
    try {
      await _ensureLocalNetworkPermission();
      final targets = only ??
          jobs
              .where((j) => j.source == JobSource.webdav && j.status.fixable)
              .toList();
      _setBatch(targets.length);
      final output = uploadCopies ? null : await outputTarget();
      for (var wi = 0; wi < targets.length; wi++) {
        final job = targets[wi];
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
        _tickBatch(wi + 1);
      }
    } finally {
      client.close();
      _setRunning(null);
      batchDone = 0;
      batchTotal = 0;
      notifyListeners();
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
    _setBatch(targets.length);
    // 文件夹任务未指定输出时就地覆盖输入（其余来源用常规输出目标）
    final output = source == JobSource.folder
        ? await folderOutputTarget()
        : await outputTarget();
    final cache = await _cache();
    try {
      for (var index = 0; index < targets.length; index++) {
        final job = targets[index];
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
        // 注意：**一律**先修复到缓存里的独立临时文件，再交给 OutputTarget 落位。
        // 不能直接写输出目录：若用户把"输出=输入"（就地覆盖，或同名文件），
        // 直写会一边读原文件一边截断它 —— 直接毁掉源文件。
        final tmp = File('${cache.path}/${job.id}-$outName');

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
            final saved = await output.save(tmp, outName);
            job.outputPath = saved;
            job.status = JobStatus.saved;
            job.message = '已保存：${job.outputPath}';
          }
        } catch (e) {
          job.status = (e is RepairCancelledException || task?.cancelled == true)
              ? JobStatus.cancelled
              : JobStatus.failed;
          job.message = job.status == JobStatus.cancelled ? '已取消' : _message(e);
        } finally {
          if (tmp.existsSync()) tmp.deleteSync();
        }
        job.progress = 0;
        _tickBatch(index + 1);
      }
    } finally {
      _setRunning(null);
      batchDone = 0;
      batchTotal = 0;
      notifyListeners();
    }
  }

  /// 清理临时文件：工作目录（修复中间产物）+ Android 侧的导入缓存（content:// 复制件）。
  ///
  /// 导入缓存由平台通道写进应用缓存目录的 `imports/`，与工作目录同级 ——
  /// 之前只清 `work/`，导致导入的整份视频副本长期占空间。
  Future<void> cleanCache() async {
    final cache = await _cache();
    _deleteContents(cache);
    try {
      final tmp = await getTemporaryDirectory();
      _deleteContents(Directory('${tmp.path}/imports'));
    } catch (_) {
      // 忽略
    }
    notifyListeners();
  }

  void _deleteContents(Directory dir) {
    if (!dir.existsSync()) return;
    for (final f in dir.listSync()) {
      try {
        f.deleteSync(recursive: true);
      } catch (_) {
        // 忽略单个失败（可能被占用）
      }
    }
  }
}
