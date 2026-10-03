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
import 'repair_ledger.dart';
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

  /// 修复记录：记住"哪个文件修好后产物在哪"，下次扫描直接复用。
  RepairLedger ledger = RepairLedger.empty();

  /// 最近一次产物路径（桌面：供「打开所在文件夹」定位）。
  String? lastSavedPath;

  /// 最近一次操作的补充提示（如"跳过了 N 个无法读取的文件夹"）。
  String? lastNotice;

  /// 批量进度（界面顶部的总进度条用）。
  int batchDone = 0;
  int batchTotal = 0;

  void _setBatch(int total) {
    batchTotal = total;
    batchDone = 0;
    _notifyTaskService(force: true);
    notifyListeners();
  }

  void _tickBatch(int done) {
    batchDone = done;
    _notifyTaskService();
    notifyListeners();
  }

  /// 任务前台服务的标题（Android；供通知使用）。
  String _taskTitle = '';

  int _lastServiceNotifyAt = 0;

  /// 同步进度到前台服务通知（最多 2 次/秒；总量未知时只显示转圈）。
  void _notifyTaskService({bool force = false}) {
    if (!AndroidPlatform.isSupported || _runningSource == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - _lastServiceNotifyAt < 500) return;
    _lastServiceNotifyAt = now;
    final done = batchDone;
    final total = batchTotal;
    unawaited(
      AndroidPlatform.updateTaskService(
        title: _taskTitle.isEmpty ? 'MP4 修复器' : _taskTitle,
        text: total > 0 ? '已完成 $done/$total' : '正在处理…',
        progress: total > 0 ? ((done / total) * 100).round() : -1,
      ),
    );
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

  /// 这个任务在当前设置下是否算「待修复」：
  /// 需重排总是算；可优化只在设置里勾了「同时处理可优化」时算
  /// （单条手动「修复这条」不受此限制）。
  bool isFixableNow(FixJob job) => shouldBatchFix(
        job.status,
        includeOptimizable: settings.includeOptimizable,
      );

  /// 是否有可修复的任务（受「同时处理可优化」设置影响）。
  bool hasFixable(JobSource source) =>
      jobs.any((j) => j.source == source && isFixableNow(j));

  /// 可修复（问题项）数量。
  int fixableCount(JobSource source) =>
      jobs.where((j) => j.source == source && isFixableNow(j)).length;

  /// "全部处理"会覆盖的数量：问题项 + 正常项（正常项也会被重新重排）。
  int processAllCount(JobSource source) => jobs
      .where(
        (j) =>
            j.source == source &&
            shouldBatchFix(
              j.status,
              includeOptimizable: settings.includeOptimizable,
              processAll: true,
            ),
      )
      .length;

  /// 其中判定为"正常"、但会被一并重排的数量。
  int normalCount(JobSource source) =>
      jobs.where((j) => j.source == source && j.status == JobStatus.ok).length;

  List<FixJob> jobsOf(JobSource source) =>
      jobs.where((j) => j.source == source).toList(growable: false);

  // ---------------------------------------------------------------- 初始化

  Future<void> init() async {
    settings = await SettingsStore.load() ?? AppSettings();
    // 恢复「记住密码」时保存的密码
    if (settings.rememberWebDavPassword && settings.webDavPassword.isNotEmpty) {
      webDavPassword = settings.webDavPassword;
    }
    await _initLedger();
    // 上次会话留下的导入副本没用了（任务列表不跨会话），开一次就清掉，别让缓存越滚越大
    unawaited(_cleanStaleCaches());
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

  /// 载入修复记录（应用支持目录；失败时退化为纯内存记录）。
  Future<void> _initLedger() async {
    File? file;
    for (final resolver in <Future<Directory> Function()>[
      getApplicationSupportDirectory,
      getApplicationDocumentsDirectory,
    ]) {
      try {
        final dir = await resolver();
        file = File('${dir.path}${Platform.pathSeparator}repair_ledger.json');
        break;
      } catch (_) {
        // 换下一个目录
      }
    }
    ledger = await RepairLedger.load(file);
  }

  Timer? _ledgerTimer;
  bool _ledgerDirty = false;

  /// 修复记录落盘（合并 2 秒内的多次写入）。
  void _scheduleLedgerSave() {
    _ledgerDirty = true;
    _ledgerTimer ??= Timer(const Duration(seconds: 2), () {
      _ledgerTimer = null;
      final dirty = _ledgerDirty;
      _ledgerDirty = false;
      if (dirty) unawaited(ledger.save());
    });
  }

  /// 立即把修复记录写盘（批处理结束时调用）。
  Future<void> flushLedger() async {
    if (!_ledgerDirty) return;
    _ledgerDirty = false;
    await ledger.save();
  }

  /// 清空修复记录（设置页「维护」用）。
  void clearLedger() {
    ledger.clear();
    notifyListeners();
    unawaited(ledger.save());
  }

  int get ledgerLength => ledger.length;

  /// 收集诊断信息（路径 / 是否存在 / 平台），便于远程排查。
  Future<String> collectDiagnostics() async {
    final lines = <String>[
      'MP4Fix 诊断信息',
      '平台: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      '设置: 阈值 ${settings.thresholdMb}MB · 含可优化=${settings.includeOptimizable}',
      '命名规则: ${settings.nameRuleId}',
      '复用修复记录: ${settings.reuseRepairs}（${ledger.length} 条）',
      '输出目标: $outputDescription',
    ];
    if (AndroidPlatform.isSupported) {
      lines.add('输出(SAF): ${settings.outputTreeUri ?? "（未选择 → 默认 下载/MP4Fix）"}');
    } else {
      final dir = settings.outputDirPath;
      lines.add('输出目录: ${dir ?? "（未选择 → 默认 下载/MP4Fix）"}');
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
    String? sourceUri,
    int modifiedMs = 0,
    bool notify = true,
  }) {
    final job = FixJob(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
      source: source,
      name: name,
      displayPath: displayPath,
      size: size,
      localPath: localPath,
      webDavUrl: webDavUrl,
      sourceUri: sourceUri,
      modifiedMs: modifiedMs,
    );
    jobs.add(job);
    if (notify) notifyListeners();
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
    if (AndroidPlatform.isSupported) {
      if (source == null) {
        unawaited(AndroidPlatform.stopTaskService());
      } else {
        _taskTitle = 'MP4 修复器 · ${_sourceLabel(source)}';
        unawaited(
          AndroidPlatform.startTaskService(
            title: _taskTitle,
            text: '正在处理…',
          ),
        );
      }
    }
    notifyListeners();
  }

  static String _sourceLabel(JobSource source) => switch (source) {
        JobSource.local => '本地文件',
        JobSource.folder => '文件夹批量',
        JobSource.webdav => 'WebDAV',
      };

  String _message(Object e) => describeError(e);

  /// 删除临时文件（尽力而为）。
  ///
  /// Windows 上文件可能被其它进程 / 刚被取消的修复 Isolate 占用，删除失败
  /// 不能把整批任务带崩；留下的文件会在「清理临时文件」里被清掉。
  void _quietDeleteFile(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // 忽略
    }
  }

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
      _quietDeleteFile(output);
      rethrow;
    } finally {
      if (identical(_activeRepair, task)) _activeRepair = null;
    }
  }

  // ---------------------------------------------------------------- 修复记录

  /// 任务的记录指纹。
  String _jobLedgerKey(FixJob job) => job.source == JobSource.webdav
      ? ledgerKeyRemote(url: job.webDavUrl ?? job.name, size: job.size)
      : ledgerKeyFile(
          name: job.name,
          size: job.size,
          modifiedMs: job.modifiedMs,
        );

  /// 取出与当前设置匹配的记录（复用开关 / 命名规则 / 指纹都要对得上）。
  RepairRecord? _recordFor(FixJob job) {
    if (!settings.reuseRepairs) return null;
    final record = ledger.lookup(_jobLedgerKey(job));
    if (record == null) return null;
    if (record.rule != settings.nameRuleId) return null;
    return record;
  }

  bool _markReused(FixJob job, RepairRecord record) {
    job.status = JobStatus.reused;
    job.outputPath = record.out;
    job.message = '复用上次修复结果：${record.out}（${record.mode}）';
    notifyListeners();
    return true;
  }

  /// 同步版复用检查（扫描回调里用）：只处理能同步确认的记录
  /// （远端副本 / 桌面目录）；Android SAF 与下载目录需要异步查询。
  bool _tryReuseSync(FixJob job) {
    final record = _recordFor(job);
    if (record == null) return false;
    final exists = switch (record.kind) {
      'remote' => true,
      'dir' => File(
        '${record.ref}${Platform.pathSeparator}${record.out}',
      ).existsSync(),
      _ => false,
    };
    if (!exists) return false;
    return _markReused(job, record);
  }

  /// 异步版复用检查（Android 上还会问一句"产物还在吗"）。
  Future<bool> _tryReuse(FixJob job) async {
    final record = _recordFor(job);
    if (record == null) return false;
    final exists = await _verifyRecord(record);
    if (!exists) {
      // 产物已经不在了 → 记录失效，重新处理
      ledger.remove(record.key);
      _scheduleLedgerSave();
      return false;
    }
    return _markReused(job, record);
  }

  Future<bool> _verifyRecord(RepairRecord record) async {
    switch (record.kind) {
      case 'remote':
        return true;
      case 'dir':
        return File(
          '${record.ref}${Platform.pathSeparator}${record.out}',
        ).existsSync();
      case 'saf':
        return AndroidPlatform.existsInTree(record.ref, record.out);
      case 'downloads':
        return AndroidPlatform.existsInDownloads(record.out);
      default:
        return true;
    }
  }

  void _recordRepair({
    required FixJob job,
    required String outName,
    required String kind,
    required String ref,
    required String mode,
  }) {
    ledger.put(
      RepairRecord(
        key: _jobLedgerKey(job),
        name: job.name,
        size: job.size,
        modifiedMs: job.modifiedMs,
        out: outName,
        kind: kind,
        ref: ref,
        mode: mode,
        rule: settings.nameRuleId,
        at: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _scheduleLedgerSave();
  }

  /// 按命名规则生成输出文件名；WebDAV 上传副本还要保证不与原文件同名
  /// （规则没改名时保底用 `_fixed` 后缀）。
  String _outputName(FixJob job) {
    final dot = job.name.lastIndexOf('.');
    final base = dot > 0 ? job.name.substring(0, dot) : job.name;
    return settings.applyOutputName('$base.mp4');
  }

  String _webDavCopyName(FixJob job) {
    final renamed = settings.applyOutputName(job.name);
    if (renamed != job.name) return renamed;
    final dot = job.name.lastIndexOf('.');
    final base = dot > 0 ? job.name.substring(0, dot) : job.name;
    final ext = dot > 0 ? job.name.substring(dot + 1) : 'mp4';
    return '${base}_fixed.$ext';
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
    return '输出：下载/MP4Fix（默认）';
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

  /// 桌面：在文件管理器里打开产物位置（最近一次产物 / 输出文件夹）。
  bool get canOpenOutputLocation => !AndroidPlatform.isSupported;

  Future<void> openOutputLocation() async {
    if (AndroidPlatform.isSupported) return;
    try {
      final target = await outputTarget();
      final dir = target.localDirectory;
      final last = lastSavedPath;
      final hasLast = last != null && File(last).existsSync();
      if (dir != null && !Directory(dir).existsSync()) {
        Directory(dir).createSync(recursive: true);
      }
      if (Platform.isWindows) {
        if (hasLast) {
          await Process.start(
            'explorer.exe',
            ['/select,${last.replaceAll('/', r'\')}'],
            mode: ProcessStartMode.detached,
          );
        } else if (dir != null) {
          await Process.start(
            'explorer.exe',
            [dir],
            mode: ProcessStartMode.detached,
          );
        }
      } else if (Platform.isMacOS) {
        if (hasLast) {
          await Process.start('open', ['-R', last],
              mode: ProcessStartMode.detached);
        } else if (dir != null) {
          await Process.start('open', [dir], mode: ProcessStartMode.detached);
        }
      } else if (dir != null) {
        await Process.start('xdg-open', [dir], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      lastNotice = _message(e);
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 拖入 / 命令行导入

  /// 把路径导入「本地文件」列表：文件直接加，文件夹递归展开（mp4 / m4v / mov）。
  ///
  /// 供 Windows 端「拖入窗口」与「用 MP4Fix 打开文件」（命令行参数）使用。
  Future<int> importPaths(List<String> paths, {String reason = '拖入'}) async {
    if (running) {
      lastNotice = '有任务正在运行，稍后再拖入';
      notifyListeners();
      return 0;
    }
    lastNotice = null;
    final created = <FixJob>[];
    for (final raw in paths) {
      final path = normalizePickedPath(raw);
      if (path.isEmpty) continue;
      final dir = Directory(path);
      final file = File(path);
      if (dir.existsSync()) {
        try {
          final listing = await Isolate.run(() => listVideosSync(path));
          for (final f in listing.files) {
            // 批量导入先不逐条通知（拖入几百个文件时避免刷新风暴），最后统一通知
            created.add(
              _newJob(
                source: JobSource.local,
                name: f.path.split(Platform.pathSeparator).last,
                displayPath: f.rel,
                size: f.size,
                localPath: f.path,
                modifiedMs: f.modifiedMs,
                notify: false,
              ),
            );
          }
        } catch (_) {
          // 单个文件夹失败不影响其它
        }
      } else if (file.existsSync()) {
        final name = path.split(Platform.pathSeparator).last;
        if (!isVideoFileName(name)) continue;
        created.add(
          _newJob(
            source: JobSource.local,
            name: name,
            displayPath: name,
            size: file.lengthSync(),
            localPath: path,
            modifiedMs: _modifiedMs(file),
            notify: false,
          ),
        );
      }
    }
    if (created.isEmpty) {
      lastNotice = '没有找到可处理的视频（支持 mp4 / m4v / mov）';
      notifyListeners();
      return 0;
    }
    lastNotice = '$reason：已导入 ${created.length} 个视频';
    notifyListeners();
    await _inspectLocalJobs(created);
    return created.length;
  }

  static int _modifiedMs(File file) {
    try {
      return file.lastModifiedSync().millisecondsSinceEpoch;
    } catch (_) {
      return 0;
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
      String? sourceUri;
      // Android：content:// 输入（非本地路径）不立刻整份复制 —— 先留着 URI，
      // 检测走「只读预取」（同 WebDAV：只取盒头 / moov / moof）；确认要修复时
      // 再复制到缓存。来源不支持随机读时自动退回"先复制再检测"。
      if (path == null &&
          f.uri.scheme == 'content' &&
          AndroidPlatform.isSupported) {
        sourceUri = f.uri.toString();
      }
      if (path == null && sourceUri == null) continue;
      if (path != null) path = normalizePickedPath(path);
      created.add(_newJob(
        source: JobSource.local,
        name: f.name,
        // 桌面显示完整路径（同名文件在不同文件夹时一眼可分），Android 只显示文件名
        displayPath:
            AndroidPlatform.isSupported ? f.name : (path ?? f.name),
        size: f.lengthSync() ?? -1,
        localPath: path,
        sourceUri: sourceUri,
        modifiedMs: path == null ? 0 : _modifiedMs(File(path)),
      ));
    }
    if (created.isEmpty) return;
    await _inspectLocalJobs(created);
    if (fixAfterPick && !_cancelRequested) {
      final fixable = created
          .where(
            (j) => shouldBatchFix(
              j.status,
              includeOptimizable: settings.includeOptimizable,
            ),
          )
          .toList();
      if (fixable.isEmpty) {
        lastNotice = '检测完成：没有需要重排的视频';
        notifyListeners();
      } else {
        await fixJobs(JobSource.local, only: fixable);
      }
    }
  }

  Future<void> _inspectLocalJobs(List<FixJob> targets) async {
    if (targets.isEmpty) return;
    _setRunning(targets.first.source);
    _setBatch(targets.length);
    for (var li = 0; li < targets.length; li++) {
      final job = targets[li];
      if (_cancelRequested) break;
      await _inspectLocalJob(job);
      _tickBatch(li + 1);
    }
    _setRunning(null);
    batchDone = 0;
    batchTotal = 0;
    notifyListeners();
  }

  /// 检测单个本地任务（含「已修复」复用判定）。
  Future<void> _inspectLocalJob(FixJob job) async {
    final path = job.localPath;
    if (path == null) {
      // Android content:// 来源：优先只读预取；不可用时退回复制到缓存
      if (job.sourceUri != null && AndroidPlatform.isSupported) {
        job.status = JobStatus.inspecting;
        job.message = '读取文件头与 moov…';
        job.progress = 0;
        notifyListeners();
        try {
          await _inspectSafJob(job);
        } catch (e) {
          job.status = JobStatus.error;
          job.message = _message(e);
        }
        await _tryReuse(job);
        notifyListeners();
        return;
      }
      job.status = JobStatus.error;
      job.message = '缺少本地文件';
      notifyListeners();
      return;
    }
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
    // 修过的文件直接标记「复用上次结果」（文件没变过才会命中）
    await _tryReuse(job);
    notifyListeners();
  }

  /// 检测一个只有 SAF `content://` URI 的任务。
  ///
  /// 优先「只读预取」（平台侧用文件描述符随机读 盒头/moov/moof，不整份复制，
  /// 与 WebDAV 扫描同一思路）；来源不支持随机读（管道类 provider）时，
  /// 自动退回"复制到缓存再检测"。
  Future<void> _inspectSafJob(FixJob job) async {
    final uri = job.sourceUri!;
    try {
      final pre = await AndroidPlatform.prefetchForInspect(uri);
      final report = await inspectPrefetchedInIsolate(
        pre.size,
        pre.ranges,
        thresholdBytes: settings.thresholdBytes,
      );
      _applyReport(job, report);
    } on SafNotSeekableException {
      job.message = '复制到缓存…';
      notifyListeners();
      final local = await AndroidPlatform.copyToCache(uri: uri, name: job.name);
      job.localPath = local;
      final report = await inspectFileInIsolate(
        local,
        thresholdBytes: settings.thresholdBytes,
      );
      _applyReport(job, report);
    }
  }

  /// 重新处理一条任务（清掉它的修复记录，重新检测 + 修复）。
  Future<void> redoJob(FixJob job) async {
    if (running || job.busy) return;
    if (ledger.remove(_jobLedgerKey(job))) _scheduleLedgerSave();
    job.status = JobStatus.pending;
    job.message = '重新检测…';
    job.outputPath = null;
    job.progress = 0;
    notifyListeners();

    if (job.source == JobSource.webdav) {
      await _reInspectWebDav(job);
      if (job.status.fixable) await fixWebDavJobs(only: [job], force: true);
      return;
    }
    // Android SAF：复用跳过了"复制到缓存"，重做时补上
    if (job.localPath == null &&
        job.sourceUri != null &&
        AndroidPlatform.isSupported) {
      _setRunning(job.source);
      job.message = '复制到缓存…';
      notifyListeners();
      try {
        job.localPath = await AndroidPlatform.copyToCache(
          uri: job.sourceUri!,
          name: job.name,
        );
      } catch (e) {
        job.status = JobStatus.error;
        job.message = _message(e);
        _setRunning(null);
        notifyListeners();
        return;
      }
      _setRunning(null);
    }
    await _inspectLocalJob(job);
    if (job.status.fixable) {
      await fixJobs(job.source, only: [job], force: true);
    }
  }

  /// 重新检测一条 WebDAV 任务（「重做」用）。
  Future<void> _reInspectWebDav(FixJob job) async {
    final item = _webDavItems[job.id];
    if (item == null) {
      job.status = JobStatus.error;
      job.message = '扫描信息已清空，请重新扫描';
      notifyListeners();
      return;
    }
    final client = _webDavClient();
    _setRunning(JobSource.webdav);
    job.status = JobStatus.inspecting;
    job.message = '重新读取 moov…';
    notifyListeners();
    try {
      await _ensureLocalNetworkPermission();
      final cache = await _cache();
      final scanner = WebDavScanner(client, threshold: settings.thresholdBytes);
      final fresh = await scanner.inspectSingle(
        item,
        tempDir: cache,
        isCancelled: () => _cancelRequested,
      );
      _webDavItems[job.id] = fresh;
      if (fresh.report != null) {
        _applyReport(job, fresh.report!);
      } else {
        job.status = JobStatus.error;
        job.message = fresh.error ?? '检测失败';
      }
    } catch (e) {
      job.status = JobStatus.error;
      job.message = _message(e);
    } finally {
      client.close();
      _setRunning(null);
      notifyListeners();
    }
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
      final fixable = targets
          .where(
            (j) => shouldBatchFix(
              j.status,
              includeOptimizable: settings.includeOptimizable,
            ),
          )
          .length;
      if (fixable == 0) {
        final optimizable =
            targets.where((j) => j.status == JobStatus.optimizable).length;
        lastNotice = optimizable > 0
            ? '扫描完成：没有需重排的视频（有 $optimizable 个「可优化」，'
                '可在设置里勾选「同时处理可优化」一并处理）'
            : '扫描完成：没有需要处理的视频';
        notifyListeners();
      } else {
        await fixJobs(JobSource.folder, only: targets);
      }
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
      _setBatch(entries.length);
      for (var i = 0; i < entries.length; i++) {
        if (_cancelRequested) break;
        final e = entries[i];
        final job = _newJob(
          source: JobSource.folder,
          name: e.name,
          displayPath: e.path,
          size: e.size,
          sourceUri: e.uri,
          modifiedMs: e.modifiedMs,
        );
        targets.add(job);
        // 已修复过（产物还在）→ 跳过检测 + 复制
        if (await _tryReuse(job)) {
          _tickBatch(i + 1);
          continue;
        }
        job.status = JobStatus.inspecting;
        job.message = '读取文件头与 moov…';
        notifyListeners();
        try {
          // 只读预取（不整份复制）；不可用时 _inspectSafJob 内部退回复制
          await _inspectSafJob(job);
        } catch (err) {
          job.status = JobStatus.error;
          job.message = _message(err);
        }
        notifyListeners();
        _tickBatch(i + 1);
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
          modifiedMs: f.modifiedMs,
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
        // 已修复过（产物还在）→ 标记复用，后面的"修复"会跳过它
        await _tryReuse(job);
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

  /// SAF 树递归列举视频（返回 uri / 展示路径 / 名称 / 大小 / 修改时间）。
  Future<
      List<
          ({
            String uri,
            String path,
            String name,
            int size,
            int modifiedMs,
          })>> _listTreeVideos(String treeUri) async {
    final saf = SafUtil();
    final out =
        <({String uri, String path, String name, int size, int modifiedMs})>[];
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
          out.add((
            uri: child.uri,
            path: rel,
            name: name,
            size: child.length,
            modifiedMs: child.lastModified,
          ));
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
            // 上次已修过（记录在案）→ 标记复用，不再重复下载重排
            _tryReuseSync(job);
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

  Future<void> fixWebDavJobs({
    bool? uploadCopies,
    List<FixJob>? only,
    bool processAll = false,
    bool force = false,
  }) async {
    if (running) return;
    uploadCopies ??= webDavUploadCopies;
    webDavUploadCopies = uploadCopies;
    final client = _webDavClient();
    _setRunning(JobSource.webdav);
    final cache = await _cache();
    final fixer = WebDavFixer(client, cacheDir: cache, repair: _isolateRepair);
    try {
      await _ensureLocalNetworkPermission();
      final base = only ??
          jobs.where((j) => j.source == JobSource.webdav).toList();
      final targets = force
          ? base
          : base
              .where(
                (j) => shouldBatchFix(
                  j.status,
                  includeOptimizable: settings.includeOptimizable,
                  processAll: processAll,
                ),
              )
              .toList();
      _setBatch(targets.length);
      final output = uploadCopies ? null : await outputTarget();
      for (var wi = 0; wi < targets.length; wi++) {
        final job = targets[wi];
        if (_cancelRequested) break;
        final item = _webDavItems[job.id];
        if (item == null) {
          job.status = JobStatus.failed;
          job.message = '扫描信息已清空，请重新扫描';
          _tickBatch(wi + 1);
          notifyListeners();
          continue;
        }
        job.status = JobStatus.fixing;
        job.progress = 0;
        job.message = uploadCopies ? '准备上传副本…' : '准备保存到本地…';
        notifyListeners();

        if (uploadCopies) {
          final copyName = _webDavCopyName(job);
          final result = await fixer.fix(
            item,
            copyName: copyName,
            onPhase: (phase, progress) {
              job.message = '$phase ${(progress * 100).round()}%';
              job.progress = progress;
              _notifyThrottled();
            },
            isCancelled: () => _cancelRequested,
          );
          _applyFixResult(job, result, uploaded: true);
          if (result.ok && result.remoteName != null) {
            _recordRepair(
              job: job,
              outName: result.remoteName!,
              kind: 'remote',
              ref: '',
              mode: 'WebDAV 上传副本',
            );
          }
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
            if (result.cancelled) {
              job.status = JobStatus.cancelled;
              job.message = '已取消';
            } else if (!result.ok) {
              job.status = JobStatus.failed;
              job.message = '失败：${result.message}';
            } else {
              final outName = settings.applyOutputName(job.name);
              try {
                final saved = await output!.save(tmp, outName);
                job.outputPath = saved;
                job.status = JobStatus.saved;
                job.message = '已保存：$saved';
                if (output.ledgerKind == 'dir') lastSavedPath = saved;
                _recordRepair(
                  job: job,
                  outName: outName,
                  kind: output.ledgerKind,
                  ref: output.ledgerRef,
                  mode: 'WebDAV 保存到本地',
                );
              } catch (e) {
                job.status = JobStatus.failed;
                job.message = '保存失败：${_message(e)}';
              }
            }
          } finally {
            if (tmp.existsSync()) _quietDeleteFile(tmp);
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
      await flushLedger();
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

  /// 修复某来源下的任务。
  ///
  /// - 默认只处理"该处理"的（需重排；勾了「同时处理可优化」时再加可优化）；
  /// - [processAll] 为真时连判定为"正常"的也一起重排（"全部处理"）；
  /// - [only] 给定时也走同一套筛选（除非 [force]，用于单条手动操作 / 重做）；
  /// - 已标记「已修复（复用）」的任务会跳过（单条「重做」才会重新处理）。
  Future<void> fixJobs(
    JobSource source, {
    List<FixJob>? only,
    bool processAll = false,
    bool force = false,
  }) async {
    if (running) return;
    final base = only ?? jobs.where((j) => j.source == source).toList();
    final targets = force
        ? base
        : base
            .where(
              (j) => shouldBatchFix(
                j.status,
                includeOptimizable: settings.includeOptimizable,
                processAll: processAll,
              ),
            )
            .toList();
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
        var inputPath = job.localPath;
        // 检测阶段做过"只读预取"（跳过了整份复制）→ 真正要修复了才复制到缓存
        if (inputPath == null &&
            job.sourceUri != null &&
            AndroidPlatform.isSupported) {
          job.status = JobStatus.fixing;
          job.progress = 0;
          job.message = '复制到缓存…';
          notifyListeners();
          try {
            inputPath = await AndroidPlatform.copyToCache(
              uri: job.sourceUri!,
              name: job.name,
            );
            job.localPath = inputPath;
          } catch (e) {
            job.status = JobStatus.failed;
            job.message = '复制失败：${_message(e)}';
            _tickBatch(index + 1);
            notifyListeners();
            continue;
          }
        }
        if (inputPath == null) {
          job.status = JobStatus.failed;
          job.message = '缺少本地文件';
          _tickBatch(index + 1);
          notifyListeners();
          continue;
        }
        job.status = JobStatus.fixing;
        job.progress = 0;
        job.message = '修复中…';
        notifyListeners();

        final outName = _outputName(job);
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
            job.message = '已保存：$saved';
            if (output.ledgerKind == 'dir') lastSavedPath = saved;
            _recordRepair(
              job: job,
              outName: outName,
              kind: output.ledgerKind,
              ref: output.ledgerRef,
              mode: source == JobSource.folder ? '文件夹批量' : '本地文件',
            );
          }
        } catch (e) {
          job.status = (e is RepairCancelledException || task?.cancelled == true)
              ? JobStatus.cancelled
              : JobStatus.failed;
          job.message = job.status == JobStatus.cancelled ? '已取消' : _message(e);
        } finally {
          if (tmp.existsSync()) _quietDeleteFile(tmp);
        }
        job.progress = 0;
        _tickBatch(index + 1);
      }
    } finally {
      _setRunning(null);
      batchDone = 0;
      batchTotal = 0;
      // 修完的导入副本（整份视频）可以删了（重做会按 sourceUri 重新复制）
      await _cleanupImportedCopies(targets);
      notifyListeners();
      await flushLedger();
    }
  }

  /// 清理「上次会话留下的导入副本」。
  ///
  /// 任务列表不跨会话，所以启动时这两处缓存都是纯垃圾：
  ///  - 平台通道复制进来的 `imports/`（文件夹扫描用的整份视频副本）；
  ///  - 文件选择器自己的缓存 `<cache>/file_picker/`。
  Future<void> _cleanStaleCaches() async {
    try {
      final tmp = await getTemporaryDirectory();
      _deleteContents(Directory('${tmp.path}/imports'));
    } catch (_) {
      // 忽略
    }
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {
      // 桌面 / 不支持的平台会直接返回
    }
  }

  /// Android：文件夹任务的导入副本（整份视频）在修复成功后就没用了 ——
  /// 「重做」会按 [FixJob.sourceUri] 重新复制，继续留着只会把缓存撑大。
  Future<void> _cleanupImportedCopies(Iterable<FixJob> targets) async {
    if (!AndroidPlatform.isSupported) return;
    try {
      final tmp = await getTemporaryDirectory();
      final prefix =
          '${tmp.path}${Platform.pathSeparator}imports${Platform.pathSeparator}';
      for (final job in targets) {
        if (!job.status.finished) continue;
        final path = job.localPath;
        if (path == null || !path.startsWith(prefix)) continue;
        _quietDeleteFile(File(path));
        job.localPath = null;
      }
    } catch (_) {
      // 忽略
    }
  }

  /// 清理临时文件：工作目录（修复中间产物）+ 导入缓存（content:// 复制件）
  /// + 文件选择器缓存。任务运行中不动（否则会删掉正在读的中间文件）。
  Future<void> cleanCache() async {
    if (running) return;
    final cache = await _cache();
    _deleteContents(cache);
    try {
      final tmp = await getTemporaryDirectory();
      _deleteContents(Directory('${tmp.path}/imports'));
    } catch (_) {
      // 忽略
    }
    try {
      await FilePicker.clearTemporaryFiles();
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

/// 小工具：条件成立时返回 [build] 的结果，否则 null。
T? if_<T>(bool condition, T Function() build) => condition ? build() : null;
