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
import '../common/parallel.dart';
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
  ///
  /// 批量处理结束时会被**汇总结果**覆盖（成功 N / 跳过 N / 失败 N，并给出原因），
  /// 所以扫完一个大目录不会只留一句"已导入 300 个视频"，而是明确告诉用户
  /// 到底修好了多少、哪些没修、为什么没修。
  String? lastNotice;

  /// 批量进度（界面顶部的总进度条用）。
  int batchDone = 0;
  int batchTotal = 0;

  /// 当前正在处理的文件名（底部状态条用它，用户能看出"卡在哪一个文件"）。
  String? currentJobName;

  /// 当前**同时**在处理的文件数（并行度 > 1 时底部状态条显示「N 个并行」）。
  int activeJobCount = 0;

  /// 清掉提示条（用户点「×」）。
  void clearNotice() {
    if (lastNotice == null) return;
    lastNotice = null;
    notifyListeners();
  }

  void _setBatch(int total) {
    batchTotal = total;
    batchDone = 0;
    _notifyTaskService(force: true);
    notifyListeners();
  }

  void _tickBatch(int done) {
    batchDone = done;
    _notifyTaskService();
    // 节流：一次只刷 10 次/秒。几千个文件的批量里，每个文件都全量重建一次界面
    // （筛选计数 + 汇总 + 列表）会让扫描过程明显卡顿；收尾时会再强制通知一次。
    _notifyThrottled();
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

  /// 当前这批任务是否已被要求停止。
  ///
  /// 公开出来是为了让「扫描阶段取消后不应自动接着修复」这条规则可被测试
  /// （见 `test/cancel_test.dart`）。
  bool get cancelRequested => _cancelRequested;

  /// 仅供测试：直接驱动运行状态机（`_setRunning` 是私有的）。
  @visibleForTesting
  void debugSetRunning(JobSource? source) => _setRunning(source);

  JobSource? get runningSource => _runningSource;

  /// 扫描 / 检测阶段的并行数。
  ///
  /// 这一阶段以「读」为主（本地随机读、SAF 预取、WebDAV Range），并行几乎
  /// 没有副作用；Android 的 SAF provider 保守一些（云端网盘并发太高反而慢）。
  int get scanParallelism => settings.parallelism > 0
      ? settings.parallelism
      : _autoParallelism(scan: true);

  /// 修复阶段的并行数。
  ///
  /// 修复是「读 + 写 + 占缓存」：每个文件都要先生成一份完整产物，
  /// 并行度直接乘以峰值缓存占用。默认值比扫描保守；超大盘建议手动设 1。
  int get repairParallelism => settings.parallelism > 0
      ? settings.parallelism
      : _autoParallelism(scan: false);

  int _autoParallelism({required bool scan}) {
    // Android 16+ 的入门机仍有不少 3~4GB 内存型号：同时开 3 个修复 Isolate
    // 再各占一份完整缓存，很容易被系统直接杀掉。低内存设备收敛到「扫描 2 /
    // 修复 1」，宁可慢一点也要跑完。
    final cores = _deviceCores > 0 ? _deviceCores : Platform.numberOfProcessors;
    final lowRam = AndroidPlatform.isSupported && _lowRamDevice;
    final cap = scan
        ? (AndroidPlatform.isSupported ? (lowRam ? 2 : 3) : 4)
        : (AndroidPlatform.isSupported ? (lowRam ? 1 : 2) : 3);
    final picked = switch (cores) {
      <= 1 => 1,
      2 => 2,
      <= 4 => scan ? (lowRam ? 2 : 3) : (lowRam ? 1 : 2),
      _ => cap,
    };
    return picked < 1 ? 1 : (picked > cap ? cap : picked);
  }

  /// 修复任务占用的缓存权重（容量单位 = 1GB）。
  ///
  /// 修复期间一个文件最多占「输入副本 + 修复产物」两份；按体积向上取整。
  /// 未知大小（-1）按最小份处理。容量 = 并行度 × 2，于是：
  /// 小文件仍能跑满并行度，3~4GB 的大文件会自动独占，避免 N 份完整缓存
  /// 同时落到磁盘上。
  int _repairWeight(int size, int parallel) {
    const gb = 1 << 30;
    if (size <= 0) return 1;
    final units = ((size + gb - 1) ~/ gb) * 2;
    final cap = parallel * 2;
    if (units < 1) return 1;
    return units > cap ? cap : units;
  }

  /// 设备能力（Android 由平台通道读取；其余平台按 CPU 核数）。
  bool _lowRamDevice = false;
  int _deviceCores = 0;

  /// 正在后台跑的那批修复（并行时可能同时有好几个；取消要全部中断）。
  final Set<RepairTask> _activeRepairs = {};

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
    // 上次运行若有未捕获异常（系统级崩溃没法从 Dart 侧看到），提示一下：
    // 详情在「设置 → 复制诊断信息」里（24 小时内的才算"最近"）。
    if (AndroidPlatform.isSupported) {
      final profile = await AndroidPlatform.deviceProfile();
      _lowRamDevice = profile.lowRam ||
          (profile.memoryClassMb > 0 && profile.memoryClassMb < 192);
      _deviceCores = profile.cores;
      final crash = await AndroidPlatform.readLastCrash();
      if (crash != null &&
          DateTime.now().millisecondsSinceEpoch - crash.time <
              const Duration(hours: 24).inMilliseconds) {
        lastNotice = '检测到上次运行异常退出（「设置 → 复制诊断信息」可查看详情）';
      }
    }
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

  // ---------------------------------------------------------------- 残留恢复

  /// 扫描输入文件夹，找出「只剩 `.mp4fix-bak`」的残留（v2.7.0 及以前的事故现场）。
  Future<List<BackupLeftover>> findBackupLeftovers() async {
    if (!AndroidPlatform.isSupported) return const [];
    final tree = settings.scanInputTreeUri;
    if (tree == null || tree.isEmpty) {
      throw StateError('请先在「文件夹」页选择要检查的文件夹');
    }
    return AndroidPlatform.listBackupLeftovers(tree);
  }

  /// 把残留的 `.mp4fix-bak` 改回正式名，返回成功数量。
  Future<int> restoreBackupLeftovers(List<BackupLeftover> items) async {
    if (!AndroidPlatform.isSupported || items.isEmpty) return 0;
    final tree = settings.scanInputTreeUri;
    if (tree == null || tree.isEmpty) return 0;
    var ok = 0;
    for (final it in items) {
      final done = await AndroidPlatform.restoreBackup(
        treeUri: tree,
        backupName: it.backupName,
        parentUri: it.parentUri,
      );
      if (done) {
        ok++;
        // 恢复出来的文件不再是「已修复」—— 它是**没修过的原片**。
        // 按名字整条清掉（路径 / 大小 / 修改时间都可能和当初的记录对不上）。
        ledger.purgeName(it.originalName);
      }
    }
    if (ok > 0) {
      _scheduleLedgerSave();
      notifyListeners();
    }
    return ok;
  }

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
    if (AndroidPlatform.isSupported) {
      final crash = await AndroidPlatform.readLastCrash();
      if (crash != null) {
        final when = DateTime.fromMillisecondsSinceEpoch(crash.time);
        final body = crash.text.length > 4000
            ? crash.text.substring(0, 4000)
            : crash.text;
        lines.add('最近一次未捕获异常（$when）：\n$body');
      } else {
        lines.add('最近一次未捕获异常：无');
      }
    }
    return lines.join('\n');
  }

  void updateSettings(void Function(AppSettings s) mutate) {
    mutate(settings);
    notifyListeners();
    _scheduleSettingsSave();
  }

  Timer? _settingsTimer;
  bool _settingsDirty = false;

  /// 设置落盘去抖：输入框逐字符触发，没必要每敲一个键就写一次文件。
  void _scheduleSettingsSave() {
    _settingsDirty = true;
    _settingsTimer ??= Timer(const Duration(milliseconds: 250), () {
      _settingsTimer = null;
      if (!_settingsDirty) return;
      _settingsDirty = false;
      unawaited(SettingsStore.save(settings));
    });
  }

  /// 立即落盘（切到后台 / 退出前调用，别把用户刚改的设置丢掉）。
  Future<void> flushSettings() async {
    _settingsTimer?.cancel();
    _settingsTimer = null;
    if (!_settingsDirty) return;
    _settingsDirty = false;
    await SettingsStore.save(settings);
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
    String relDir = '',
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
      relDir: relDir,
    );
    jobs.add(job);
    // 扫描大目录时每个文件都会 new 一条：以前每次都全量 notify（几十万次），
    // 列表重建风暴会让扫描本身变慢。这里统一走 10 次/秒的节流。
    if (notify) _notifyThrottled();
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
    // 正在跑引擎的 Isolate：立即全部杀掉，不必等当前文件修完
    for (final task in _activeRepairs.toList(growable: false)) {
      task.cancel();
    }
    _activeRepairs.clear();
    // 正在落位 / 复制到缓存的平台侧 IO：同样要中断（大文件复制动辄几分钟）
    unawaited(AndroidPlatform.cancelPlatformWrite());
    notifyListeners();
  }

  void _setRunning(JobSource? source) {
    _runningSource = source;
    // 只在「开始一个新任务」时清掉取消标记。
    //
    // 以前这里无条件 `_cancelRequested = false`，而 `_setRunning(null)`（任务
    // 结束）也会走到 —— 于是 `scanFolder()` / `scanWebDav()` 在 finally 里复位
    // 运行状态后，紧接着的 `if (fixAfterScan && !_cancelRequested)` 永远为真：
    // 用户在扫描阶段点了「停止」，扫描确实停了，**但立刻又照着已经扫到的列表
    // 开始批量修复**，取消形同虚设。
    if (source != null) _cancelRequested = false;
    if (AndroidPlatform.isSupported) {
      if (source == null) {
        AndroidPlatform.endWriteBatch();
        unawaited(AndroidPlatform.stopTaskService());
      } else {
        // 平台写入固定在本批次的取消代数上：停止之后才开始的 SAF 拷贝
        // 也会立刻中止（并行时任务切换很频繁，这个窗口不能留）。
        unawaited(AndroidPlatform.beginWriteBatch());
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

  // ---------------------------------------------------------------- 结果汇总

  /// 这批任务里各状态的计数（供结束时的汇总提示使用）。
  ({int ok, int skipped, int failed, int cancelled}) _tally(
    Iterable<FixJob> jobs,
  ) {
    var ok = 0, skipped = 0, failed = 0, cancelled = 0;
    for (final j in jobs) {
      final s = j.status;
      if (s == JobStatus.saved || s == JobStatus.uploaded) {
        ok++;
      } else if (s == JobStatus.reused) {
        skipped++;
      } else if (s == JobStatus.failed ||
          s == JobStatus.corrupt ||
          s == JobStatus.unsupported ||
          s == JobStatus.error) {
        failed++;
      } else if (s == JobStatus.cancelled) {
        cancelled++;
      }
    }
    return (ok: ok, skipped: skipped, failed: failed, cancelled: cancelled);
  }

  /// 生成「这批到底发生了什么」的一句话汇总。
  ///
  /// 失败时**带上第一条原因** —— 只显示「失败 12 个」用户还得逐条点开看；
  /// 带上原因（例如"文件被其他程序占用"）往往当场就能自己解决。
  String _summaryLine(Iterable<FixJob> jobs) {
    final t = _tally(jobs);
    if (t.ok == 0 && t.skipped == 0 && t.failed == 0 && t.cancelled == 0) {
      return '';
    }
    final parts = <String>[
      if (t.ok > 0) '修复完成 ${t.ok} 个',
      if (t.skipped > 0) '已修复过、跳过 ${t.skipped} 个',
      if (t.failed > 0) '失败 ${t.failed} 个',
      if (t.cancelled > 0) '已取消 ${t.cancelled} 个',
    ];
    var line = parts.join(' · ');
    if (t.failed > 0) {
      final first = jobs.firstWhere(
        (j) =>
            j.status == JobStatus.failed ||
            j.status == JobStatus.corrupt ||
            j.status == JobStatus.unsupported ||
            j.status == JobStatus.error,
      );
      final reason = first.message.trim();
      if (reason.isNotEmpty) {
        line = '$line（首个原因：${first.name} — $reason）';
      }
    }
    return line;
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

  /// 供修复流水线使用的修复执行器：在后台 Isolate 中跑引擎，避免卡住界面。
  ///
  /// **所有修复都必须走这里**（本地 / 文件夹 / WebDAV）。以前本地与文件夹任务
  /// 直接 `RepairTask.start(...)` 拿了个局部变量，没有登记到 [_activeRepair] ——
  /// 于是「停止」只是把 `_cancelRequested` 置真，**正在修的那个文件会一路修完**
  /// （几 GB 的文件要等好几分钟），用户以为按钮没反应。
  /// 现在统一登记，`requestCancel()` 能立刻杀掉 Isolate。
  Future<RepairTask> _isolateRepair({
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
    _activeRepairs.add(task);
    // 取消可能刚好发生在「检查 _cancelRequested 通过」和「Isolate 起来」之间：
    // 此时 requestCancel 已经清空集合、走完了，这个任务会漏网。
    // 登记后再补一次检查，保证「停止」之后不会再有几个文件偷偷修完。
    if (_cancelRequested) task.cancel();
    try {
      await task.done;
    } catch (_) {
      _quietDeleteFile(output);
      rethrow;
    } finally {
      _activeRepairs.remove(task);
    }
    return task;
  }

  // ---------------------------------------------------------------- 修复记录

  /// 任务的记录指纹。
  ///
  /// [FixJob.sourceUri] 优先：SAF / content:// 任务在修复前只有 URI，修复后会
  /// 多出一个缓存副本路径 —— 用「先 localPath 再 displayPath」这种写法会让同一次
  /// 修复前后算出两个不同的键，记录永远对不上。
  String _jobLedgerKey(FixJob job) => job.source == JobSource.webdav
      ? ledgerKeyRemote(url: job.webDavUrl ?? job.name, size: job.size)
      : ledgerKeyFile(
          name: job.name,
          size: job.size,
          modifiedMs: job.modifiedMs,
          path: job.sourceUri ?? job.localPath ?? job.displayPath,
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

  /// [WebDavFixer] 用的执行器适配：它不关心返回值。
  Future<void> _webDavRepair({
    required File input,
    required File output,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    await _isolateRepair(
      input: input,
      output: output,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  /// 修复记录里的产物相对路径（`sub/a.mp4`）。
  ///
  /// 记录里的 `out` 必须带相对目录，否则「产物还在吗」会去根目录找 ——
  /// 子目录里的产物永远找不到，复用每次都失效。
  static String _relativeOut(String subDir, String name) =>
      subDir.isEmpty ? name : '$subDir/$name';

  /// 按命名规则生成输出文件名。
  ///
  /// **保留原扩展名**：以前这里硬编码成 `.mp4`，于是 `.mov` / `.m4v` 修复后
  /// 会变成 `同名.mp4` —— 在「就地覆盖输入文件夹」模式下，产物名和原文件对不上，
  /// 结果是**原 `.mov` 没被替换，反而多出一个 `.mp4`**，用户看到的就是
  /// 「修完了但文件夹里多了一堆文件、原文件还是卡的」。
  /// 输出路径归一化（大小写不敏感 + 统一分隔符），用于重名判定。
  static String _outputKey(String relativePath) =>
      relativePath.replaceAll('\\', '/').toLowerCase();

  /// 修复记录里「已经属于别的源文件」的输出名 → 源指纹。
  ///
  /// 只取同一输出位置、同一命名规则的记录；重做单个文件时，分配器靠它
  /// 避开同批其他文件的产物。
  Map<String, String> _reservedOutputNames(OutputTarget output) {
    final reserved = <String, String>{};
    for (final record in ledger.records) {
      if (record.rule != settings.nameRuleId) continue;
      if (record.kind != output.ledgerKind || record.ref != output.ledgerRef) {
        continue;
      }
      reserved[_outputKey(record.out)] = record.key;
    }
    return reserved;
  }

  String _outputName(FixJob job) {
    final dot = job.name.lastIndexOf('.');
    if (dot <= 0 || dot == job.name.length - 1) {
      // 没有扩展名 → 保持无扩展名，交给命名规则
      return sanitizeOutputFileName(settings.applyOutputName(job.name));
    }
    final base = job.name.substring(0, dot);
    final ext = job.name.substring(dot); // 含点，保留原大小写
    return sanitizeOutputFileName(settings.applyOutputName('$base$ext'));
  }

  String _webDavCopyName(FixJob job) {
    final renamed = settings.applyOutputName(job.name);
    if (renamed != job.name) return sanitizeOutputFileName(renamed);
    final dot = job.name.lastIndexOf('.');
    final base = dot > 0 ? job.name.substring(0, dot) : job.name;
    final ext = dot > 0 ? job.name.substring(dot + 1) : 'mp4';
    return sanitizeOutputFileName('${base}_fixed.$ext');
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

  /// SAF tree URI → 展示名。实现在 [treeUriDisplayName]（纯函数、可单测）；
  /// 这里只做转发，**不要**再就地写一套解码逻辑 —— 之前那版重复解码，
  /// 中文文件夹名直接把文件夹页炸成白屏。
  String _treeName(String treeUri) => treeUriDisplayName(treeUri);

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
      ' / ${settings.thresholdSeconds.toStringAsFixed(1)} 秒'
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
      // 两个 flag 都不能省：
      //  - `persistablePermission`：不加就只在本次进程内有效，URI 虽然写进了
      //    settings.json，重启后权限已失效 → 扫描直接 SecurityException；
      //  - `writePermission`：默认行为是「没选输出文件夹就地覆盖输入文件夹」
      //    （见 folderOutputTarget），只拿读权限时 createDocument 会抛
      //    SecurityException —— 表现为「每个文件都修复失败」。
      final dir = await SafUtil().pickDirectory(
        writePermission: true,
        persistablePermission: true,
      );
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
    var skipped = 0;

    /// 同一个文件重复拖入（或拖入的文件已经在列表里）→ 不重复加。
    /// 以前只在「添加视频」里判重，拖入没有 —— 同一部片子拖两次就会变成两条
    /// 任务，修复两遍、互相覆盖输出。
    bool alreadyAdded(String path, String name) => jobs.any(
      (j) =>
          j.source == JobSource.local &&
          j.name == name &&
          j.localPath == path,
    );

    for (final raw in paths) {
      final path = normalizePickedPath(raw);
      if (path.isEmpty) continue;
      final dir = Directory(path);
      final file = File(path);
      if (dir.existsSync()) {
        try {
          final listing = await Isolate.run(() => listVideosSync(path));
          for (final f in listing.files) {
            final name = f.path.split(Platform.pathSeparator).last;
            if (alreadyAdded(f.path, name)) {
              skipped++;
              continue;
            }
            // 批量导入先不逐条通知（拖入几百个文件时避免刷新风暴），最后统一通知
            created.add(
              _newJob(
                source: JobSource.local,
                name: name,
                displayPath: f.rel,
                size: f.size,
                localPath: f.path,
                modifiedMs: f.modifiedMs,
                relDir: relativeDirOf(f.rel),
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
        if (alreadyAdded(path, name)) {
          skipped++;
          continue;
        }
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
      lastNotice = skipped > 0
          ? '这 $skipped 个视频已经在列表里了'
          : '没有找到可处理的视频（支持 mp4 / m4v / mov）';
      notifyListeners();
      return 0;
    }
    lastNotice = skipped > 0
        ? '$reason：已导入 ${created.length} 个视频（跳过 $skipped 个已在列表里的）'
        : '$reason：已导入 ${created.length} 个视频';
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
    var skipped = 0;
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

      // 同一个文件已经在列表里（重复点「添加视频」）→ 跳过，不要生成重复任务。
      // 否则同一文件会被检测两次、修两次，还可能互相覆盖输出。
      final already = jobs.any(
        (j) =>
            j.source == JobSource.local &&
            j.name == f.name &&
            ((path != null && j.localPath == path) ||
                (sourceUri != null && j.sourceUri == sourceUri)),
      );
      if (already) {
        skipped++;
        continue;
      }

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
    if (skipped > 0) {
      lastNotice = '已跳过 $skipped 个已在列表里的文件';
      notifyListeners();
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
    var completed = 0;
    try {
      // 检测一个文件 99% 的时间在等 IO（打开文件 / 读 moov / SAF 预取），
      // 串行做等于让磁盘和 CPU 互相等；这里最多同时检测 scanParallelism 个。
      await forEachBounded(
        targets,
        scanParallelism,
        (job, _) async {
          currentJobName = job.name;
          activeJobCount++;
          try {
            await _inspectLocalJob(job);
          } catch (e) {
            job.status = JobStatus.error;
            job.message = _message(e);
          } finally {
            activeJobCount--;
            _tickBatch(++completed);
          }
        },
        isCancelled: () => _cancelRequested,
      );
    } finally {
      _setRunning(null);
      batchDone = 0;
      batchTotal = 0;
      currentJobName = null;
      activeJobCount = 0;
      notifyListeners();
    }
  }

  /// 检测单个本地任务（含「已修复」复用判定）。
  Future<void> _inspectLocalJob(FixJob job) async {
    // ★ 先查修复记录：产物还在就直接标「已修复」，跳过检测。
    //   桌面目录能同步确认产物存在，所以这里可以前置判定。
    if (await _tryReuse(job)) {
      _notifyThrottled();
      return;
    }
    final path = job.localPath;
    if (path == null) {
      // Android content:// 来源：优先只读预取；不可用时退回复制到缓存
      if (job.sourceUri != null && AndroidPlatform.isSupported) {
        job.status = JobStatus.inspecting;
        job.message = '读取文件头与 moov…';
        job.progress = 0;
        _notifyThrottled();
        try {
          await _inspectSafJob(job);
        } catch (e) {
          job.status = JobStatus.error;
          job.message = _message(e);
        }
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
    _notifyThrottled();
    try {
      final report = await inspectFileInIsolate(
        path,
        thresholdBytes: settings.thresholdBytes,
        thresholdSeconds: settings.thresholdSeconds,
      );
      _applyReport(job, report);
    } catch (e) {
      job.status = JobStatus.error;
      job.message = _message(e);
    }
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
        thresholdSeconds: settings.thresholdSeconds,
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
        thresholdSeconds: settings.thresholdSeconds,
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
      final scanner = WebDavScanner(
        client,
        threshold: settings.thresholdBytes,
        thresholdSeconds: settings.thresholdSeconds,
      );
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
    // ★ 重新扫描前先清掉上一轮的文件夹任务。
    //   以前不清：同一个文件夹点两次「仅扫描」，列表会变成两倍（重复条目），
    //   「扫描并修复」再点一次更糟 —— 同一文件被排进两批、修两遍。
    //   _cleared 会保留快照，用户仍可用「撤销」找回（与「清空」一致）。
    if (jobsOf(JobSource.folder).isNotEmpty) clearJobs(JobSource.folder);
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
    } else {
      // 仅扫描 / 扫描中途停止：同样给一句结果汇总，别让用户自己数列表
      final summary = _scanSummary(targets);
      if (summary.isNotEmpty) lastNotice = summary;
      notifyListeners();
    }
  }

  /// 「这次扫描到底扫出了什么」的一句话汇总。
  String _scanSummary(List<FixJob> targets) {
    if (targets.isEmpty) return '';
    var needsFix = 0, optimizable = 0, ok = 0, bad = 0, reused = 0;
    for (final j in targets) {
      switch (j.status) {
        case JobStatus.needsFix:
          needsFix++;
        case JobStatus.optimizable:
          optimizable++;
        case JobStatus.ok:
          ok++;
        case JobStatus.reused:
          reused++;
        case JobStatus.corrupt:
        case JobStatus.unsupported:
        case JobStatus.error:
        case JobStatus.failed:
          bad++;
        default:
          break;
      }
    }
    final parts = <String>[
      if (needsFix > 0) '需重排 $needsFix 个',
      if (optimizable > 0) '可优化 $optimizable 个',
      if (bad > 0) '读取失败 $bad 个',
      if (ok > 0) '正常 $ok 个',
      if (reused > 0) '已修复过 $reused 个',
    ];
    final head = _cancelRequested ? '已停止：' : '扫描完成：';
    final tail = parts.isEmpty ? '没有可处理的视频' : parts.join(' · ');
    return '$head${targets.length} 个视频，$tail';
  }

  /// scanFolder 的实际工作（外层负责运行状态复位）。
  Future<void> _scanFolderInner(List<FixJob> targets) async {
    if (AndroidPlatform.isSupported) {
      final tree = settings.scanInputTreeUri;
      if (tree == null || tree.isEmpty) {
        throw StateError('请先选择输入文件夹');
      }
      _setRunning(JobSource.folder);
      final listing = await _listTreeVideos(tree);
      final entries = listing.files;
      _setBatch(entries.length);
      if (listing.truncated && entries.length >= _maxScanFiles) {
        lastNotice = '文件夹太大了：只处理了前 ${entries.length} 个视频'
            '（上限 $_maxScanFiles 个视频 / $_maxScanDirs 个目录）。'
            '剩下的请分几个子文件夹再扫一次。';
      }
      var completed = 0;
      // 每个文件的检测都要经过平台通道（开 FD + 跳读盒头/moov）+ 后台 Isolate 解析，
      // 串行时这两段互相等；并行后实际耗时通常能压到 1/2~1/3。
      await forEachBounded(
        entries,
        scanParallelism,
        (e, _) async {
          final job = _newJob(
            source: JobSource.folder,
            name: e.name,
            displayPath: e.path,
            size: e.size,
            sourceUri: e.uri,
            modifiedMs: e.modifiedMs,
            relDir: relativeDirOf(e.path),
          );
          targets.add(job);
          currentJobName = e.name;
          activeJobCount++;
          try {
            // 已修复过（产物还在）→ 跳过检测 + 复制
            if (await _tryReuse(job)) return;
            job.status = JobStatus.inspecting;
            job.message = '读取文件头与 moov…';
            _notifyThrottled();
            try {
              // 只读预取（不整份复制）；不可用时 _inspectSafJob 内部退回复制
              await _inspectSafJob(job);
            } catch (err) {
              job.status = JobStatus.error;
              job.message = _message(err);
            }
            _notifyThrottled();
          } catch (err) {
            // 复用查询 / 状态更新等意外错误：给这一条一个明确结果，
            // 不能让它永远停在「待检测」。
            job.status = JobStatus.error;
            job.message = _message(err);
          } finally {
            activeJobCount--;
            _tickBatch(++completed);
          }
        },
        isCancelled: () => _cancelRequested,
      );
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
      var completed = 0;
      await forEachBounded(
        listing.files,
        scanParallelism,
        (f, _) async {
          final job = _newJob(
            source: JobSource.folder,
            name: f.path.split(Platform.pathSeparator).last,
            displayPath: f.rel,
            size: f.size,
            localPath: f.path,
            modifiedMs: f.modifiedMs,
            relDir: relativeDirOf(f.rel),
          );
          targets.add(job);
          currentJobName = f.path.split(Platform.pathSeparator).last;
          activeJobCount++;
          try {
            // ★ 先查修复记录：命中且产物还在 → 直接标「已修复」，**跳过检测**。
            //   之前这段放在检测之后，等于「复用」只省了修复、没省检测 ——
            //   已修复过的大目录重新扫描，仍然要把每个文件的 moov 全部解析一遍。
            //   桌面目录可以用 existsSync 同步确认，所以能在检测前判定。
            if (await _tryReuse(job)) return;
            job.status = JobStatus.inspecting;
            _notifyThrottled();
            try {
              final report = await inspectFileInIsolate(
                f.path,
                thresholdBytes: settings.thresholdBytes,
                thresholdSeconds: settings.thresholdSeconds,
              );
              _applyReport(job, report);
            } catch (err) {
              job.status = JobStatus.error;
              job.message = _message(err);
            }
          } catch (err) {
            job.status = JobStatus.error;
            job.message = _message(err);
          } finally {
            activeJobCount--;
            _tickBatch(++completed);
          }
        },
        isCancelled: () => _cancelRequested,
      );
    }
  }

  /// 单次 SAF 扫描的上限：目录数 / 视频数。
  ///
  /// 撞到上限时结果不完整，界面会明确提示（别让用户以为「整个文件夹就这么多」）。
  static const int _maxScanDirs = 20000;
  static const int _maxScanFiles = 200000;

  /// SAF 树递归列举视频（返回 uri / 展示路径 / 名称 / 大小 / 修改时间）。
  ///
  /// [truncated] 为真表示撞到了目录数 / 文件数上限，结果**不是完整的** ——
  /// 以前这里直接 break 而不吭声，用户看到的只是「扫描完成：没有需要处理的视频」，
  /// 完全不知道为什么少了一半文件。
  Future<
      ({
        List<
            ({
              String uri,
              String path,
              String name,
              int size,
              int modifiedMs,
            })> files,
        bool truncated,
      })> _listTreeVideos(String treeUri) async {
    final saf = SafUtil();
    var truncated = false;
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
      if (visited.length > _maxScanDirs || out.length > _maxScanFiles) {
        truncated = true;
        break;
      }
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
        } else if (isVideoFileName(name)) {
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
    return (files: out, truncated: truncated || _cancelRequested);
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
      _scheduleSettingsSave();
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
  ///
  /// 这是**唯一状态源**：页面上的分段按钮通过 [setWebDavUploadCopies] 改它，
  /// 所有「修复全部 / 全部处理 / 扫描并修复」都读它。以前页面自己存了一份
  /// `_uploadCopies`，而底部按钮调的是 `fixWebDavJobs()`（不带参数）——
  /// 选了「保存到本地」仍然按上一次扫描的默认值上传副本。
  bool webDavUploadCopies = true;

  /// 切换 WebDAV 输出模式（页面按钮用；会通知界面刷新）。
  void setWebDavUploadCopies(bool value) {
    if (webDavUploadCopies == value) return;
    webDavUploadCopies = value;
    notifyListeners();
  }

  /// 扫描 WebDAV 目录（可选修复）。
  ///
  /// [uploadCopies] 为空时沿用当前模式 ——「仅扫描」不能把用户刚选的
  /// 「保存到本地」重置回「上传副本」。
  Future<void> scanWebDav({
    bool fixAfterScan = false,
    bool? uploadCopies,
  }) async {
    if (running) return;
    if (uploadCopies != null) webDavUploadCopies = uploadCopies;
    // ★ 重新扫描前清掉上一轮的 WebDAV 任务。
    //   v2.7.0 修过「文件夹重复扫描把列表翻倍」，但**同样的问题在 WebDAV 这侧
    //   一直没修**：同一个目录点两次「仅扫描」，条目变两倍，「扫描并修复」会把
    //   同一批文件各修两遍。`_cleared` 会保留快照，仍可用「撤销」找回。
    if (jobsOf(JobSource.webdav).isNotEmpty) clearJobs(JobSource.webdav);
    final client = _webDavClient();
    _setRunning(JobSource.webdav);
    try {
      final cache = await _cache();
      await _ensureLocalNetworkPermission();
      final scanner = WebDavScanner(
        client,
        threshold: settings.thresholdBytes,
        thresholdSeconds: settings.thresholdSeconds,
        fileConcurrency: scanParallelism,
        // 目录列举比文件检测更轻：上限 3 路（低内存设备跟着降到 2）
        dirConcurrency: scanParallelism < 3 ? scanParallelism : 3,
      );
      await scanner.scan(
        client.root,
        tempDir: cache,
        onFile: (item) {
          final job = _newJob(
            source: JobSource.webdav,
            name: item.name,
            displayPath: item.path,
            size: item.size,
            webDavUrl: item.url,
            // 「保存到本地」要保留远端子目录：否则不同目录下的同名文件
            // 会全部落到输出根目录，后一个覆盖前一个（并行时更隐蔽）。
            relDir: relativeDirOf(item.path),
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
          currentJobName = item.name;
          // 扫描时文件是一个一个回报的：并行后完成顺序不定，重建节流到 10 次/秒
          _notifyThrottled();
        },
        isCancelled: () => _cancelRequested,
      );
    } finally {
      client.close();
      _setRunning(null);
    }
    if (fixAfterScan && !_cancelRequested) {
      await fixWebDavJobs();
    } else {
      final summary = _scanSummary(jobsOf(JobSource.webdav));
      if (summary.isNotEmpty) lastNotice = summary;
      notifyListeners();
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
    // 声明在 try 之外：finally 里的结果汇总要用到这批任务
    List<FixJob> targets = const [];
    try {
      final cache = await _cache();
      final fixer = WebDavFixer(client, cacheDir: cache, repair: _webDavRepair);
      await _ensureLocalNetworkPermission();
      final base = only ??
          jobs.where((j) => j.source == JobSource.webdav).toList();
      targets = force
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
      final parallel = repairParallelism;
      // 与本地修复共用同一套「缓存预算」：WebDAV 下载 + 修复产物也是两份。
      final gate = WeightedSemaphore(parallel * 2);
      // 「保存到本地」同样要防止同批产物重名（命名规则清洗后可能撞名）。
      final names = output == null
          ? OutputNameAllocator()
          : OutputNameAllocator(reserved: _reservedOutputNames(output));
      var completed = 0;
      // 一个文件分「下载 → 修复 → 上传」三段，每段都在等网络 / 磁盘。
      // 同时跑几个文件，天然形成流水线：A 在上传时，B 已经在下一条下载。
      await forEachBounded(
        targets,
        parallel,
        (job, _) async {
          if (_cancelRequested) return;
          final localOutName = uploadCopies!
              ? null
              : names.allocate(
                  job.relDir,
                  sanitizeOutputFileName(settings.applyOutputName(job.name)),
                  sourceKey: _jobLedgerKey(job),
                );
          try {
            await gate.run(_repairWeight(job.size, parallel), () async {
              if (_cancelRequested) return;
              currentJobName = job.name;
              activeJobCount++;
              try {
                await _fixWebDavJob(
                  job,
                  uploadCopies: uploadCopies!,
                  fixer: fixer,
                  cache: cache,
                  output: output,
                  localOutName: localOutName,
                );
              } finally {
                activeJobCount--;
              }
            });
          } catch (e) {
            job.status = JobStatus.failed;
            job.progress = 0;
            job.message = _message(e);
          } finally {
            _tickBatch(++completed);
          }
        },
        isCancelled: () => _cancelRequested,
      );
    } finally {
      client.close();
      _setRunning(null);
      batchDone = 0;
      batchTotal = 0;
      currentJobName = null;
      activeJobCount = 0;
      final summary = _summaryLine(targets);
      if (summary.isNotEmpty) lastNotice = summary;
      notifyListeners();
      await flushLedger();
    }
  }

  /// 修复单个 WebDAV 任务（上传副本 / 保存到本地）。
  Future<void> _fixWebDavJob(
    FixJob job, {
    required bool uploadCopies,
    required WebDavFixer fixer,
    required Directory cache,
    required OutputTarget? output,
    String? localOutName,
  }) async {
    final item = _webDavItems[job.id];
    if (item == null) {
      job.status = JobStatus.failed;
      job.message = '扫描信息已清空，请重新扫描';
      notifyListeners();
      return;
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
        } else if (output == null) {
          job.status = JobStatus.failed;
          job.message = '保存失败：没有可用的输出位置';
        } else {
          final outName = localOutName ??
              sanitizeOutputFileName(settings.applyOutputName(job.name));
          try {
            final saved = await output.save(
              tmp,
              outName,
              subDir: job.relDir,
            );
            job.outputPath = saved;
            job.status = JobStatus.saved;
            job.message = '已保存：$saved';
            if (output.ledgerKind == 'dir') lastSavedPath = saved;
            _recordRepair(
              job: job,
              outName: _relativeOut(job.relDir, outName),
              kind: output.ledgerKind,
              ref: output.ledgerRef,
              mode: 'WebDAV 保存到本地',
            );
          } catch (e) {
            final cancelled = e is SafWriteCancelledException;
            job.status = cancelled ? JobStatus.cancelled : JobStatus.failed;
            job.message = cancelled
                ? '已取消（原文件未改动）'
                : '保存失败：${_message(e)}';
          }
        }
      } finally {
        if (tmp.existsSync()) _quietDeleteFile(tmp);
      }
    }
    job.progress = 0;
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
    // 注意：`outputTarget()` / `_cache()` 都可能抛（没有下载目录、path_provider
    // 失败…）。它们必须待在 try 里 —— 否则 `_setRunning(null)` 不会执行，
    // `running` 永久为真，界面上所有按钮（添加 / 扫描 / 修复 / 设置）从此全是
    // disabled，只能杀进程。
    try {
      // 文件夹任务未指定输出时就地覆盖输入（其余来源用常规输出目标）
      final output = source == JobSource.folder
          ? await folderOutputTarget()
          : await outputTarget();
      final cache = await _cache();
      final parallel = repairParallelism;
      // 缓存预算：每个文件最多同时占「输入副本 + 修复产物」两份，
      // 按 1GB 折算；大文件自动少开，避免 3 个 4GB 文件同时产生 24GB 临时数据。
      final gate = WeightedSemaphore(parallel * 2);
      // 同一批里不同源文件可能被命名规则清洗成同一个目标名；
      // 在开始等缓存闸门前先按顺序分配唯一名字，避免落位时互相覆盖。
      // 修复记录里已有的归属也要避开（单独重做时不能覆盖同批其他文件）。
      final names = OutputNameAllocator(
        reserved: _reservedOutputNames(output),
      );
      var completed = 0;
      // 修复是「读原片 + 写产物 + 落位」的长任务，串行时磁盘几乎一直半空转。
      // 并行度默认比扫描保守（见 repairParallelism）：每个文件都占一份缓存。
      await forEachBounded(
        targets,
        parallel,
        (job, _) async {
          if (_cancelRequested) return;
          final outName = names.allocate(
            job.relDir,
            _outputName(job),
            sourceKey: _jobLedgerKey(job),
          );
          try {
            await gate.run(_repairWeight(job.size, parallel), () async {
              if (_cancelRequested) return;
              currentJobName = job.name;
              activeJobCount++;
              try {
                await _fixLocalJob(
                  job,
                  outName: outName,
                  source: source,
                  output: output,
                  cache: cache,
                );
              } finally {
                activeJobCount--;
              }
            });
          } catch (e) {
            // _fixLocalJob 内部已兜底；这里再拦一层，避免未知异常把任务
            // 永久留在「修复中」状态（列表看着像卡住）。
            job.status = JobStatus.failed;
            job.progress = 0;
            job.message = _message(e);
          } finally {
            _tickBatch(++completed);
          }
        },
        isCancelled: () => _cancelRequested,
      );
    } finally {
      _setRunning(null);
      batchDone = 0;
      batchTotal = 0;
      currentJobName = null;
      activeJobCount = 0;
      // 修完的导入副本（整份视频）可以删了（重做会按 sourceUri 重新复制）
      await _cleanupImportedCopies(targets);
      // 结束时给一句汇总（成功 / 跳过 / 失败 + 首个失败原因）
      final summary = _summaryLine(targets);
      if (summary.isNotEmpty) lastNotice = summary;
      notifyListeners();
      await flushLedger();
    }
  }

  /// 修复单个本地 / 文件夹任务（输出落位、修复记录、取消语义都在这里）。
  Future<void> _fixLocalJob(
    FixJob job, {
    required String outName,
    required JobSource source,
    required OutputTarget output,
    required Directory cache,
  }) async {
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
        final cancelled = _cancelRequested || e is SafWriteCancelledException;
        job.status = cancelled ? JobStatus.cancelled : JobStatus.failed;
        job.message = cancelled ? '已取消' : '复制失败：${_message(e)}';
        notifyListeners();
        return;
      }
    }
    if (inputPath == null) {
      job.status = JobStatus.failed;
      job.message = '缺少本地文件';
      notifyListeners();
      return;
    }
    job.status = JobStatus.fixing;
    job.progress = 0;
    job.message = '修复中…';
    notifyListeners();

    // 注意：**一律**先修复到缓存里的独立临时文件，再交给 OutputTarget 落位。
    // 不能直接写输出目录：若用户把"输出=输入"（就地覆盖，或同名文件），
    // 直写会一边读原文件一边截断它 —— 直接毁掉源文件。
    final tmp = File('${cache.path}/${job.id}-$outName');
    // 递归扫描时产物落回原文件所在子目录 —— 否则子目录里的同名文件
    // 会在输出根目录上互相覆盖（就地覆盖模式下还会在根目录多出一份）
    final subDir = job.relDir;

    RepairTask? task;
    try {
      // 走统一执行器：登记到 _activeRepairs，「停止」才能真正中断它。
      task = await _isolateRepair(
        input: File(inputPath),
        output: tmp,
        onProgress: (done, total) {
          if (total > 0) {
            job.progress = done / total;
            job.message = '修复中 ${(job.progress * 100).round()}%';
            _notifyThrottled();
          }
        },
        isCancelled: () => _cancelRequested,
      );
      if (_cancelRequested) {
        job.status = JobStatus.cancelled;
        job.message = '已取消';
      } else {
        // ★ 覆盖前的最后一道闸：产物必须完整可解析，否则绝不落位。
        //   覆盖是**不可逆**的 —— 就地覆盖模式下写坏了，用户的原片就没了。
        //   校验要读并解析 moov：放到后台 Isolate，避免并行修复时
        //   每个产物都在 UI 线程上卡一下（大 moov 可达上百毫秒）。
        final invalid = await validateRepairOutputInIsolate(
          tmp,
          expectedBytes: task.outputBytes,
        );
        if (invalid != null) {
          job.status = JobStatus.failed;
          job.message = '已中止覆盖：$invalid（原文件未改动）';
        } else {
          final saved = await output.save(tmp, outName, subDir: subDir);
          job.outputPath = saved;
          job.status = JobStatus.saved;
          job.message = '已保存：$saved';
          if (output.ledgerKind == 'dir') lastSavedPath = saved;
          _recordRepair(
            job: job,
            outName: _relativeOut(subDir, outName),
            kind: output.ledgerKind,
            ref: output.ledgerRef,
            mode: source == JobSource.folder ? '文件夹批量' : '本地文件',
          );
        }
      }
    } catch (e) {
      final cancelled = e is RepairCancelledException ||
          e is SafWriteCancelledException ||
          task?.cancelled == true;
      job.status = cancelled ? JobStatus.cancelled : JobStatus.failed;
      job.message = cancelled
          ? (e is SafWriteCancelledException
              ? '已取消（原文件未改动）'
              : '已取消')
          : _message(e);
    } finally {
      if (tmp.existsSync()) _quietDeleteFile(tmp);
    }
    job.progress = 0;
  }

  /// 清理「上次会话留下的导入副本」。
  ///
  /// 任务列表不跨会话，所以启动时这两处缓存都是纯垃圾：
  ///  - 平台通道复制进来的 `imports/`（文件夹扫描用的整份视频副本）；
  ///  - 文件选择器自己的缓存 `<cache>/file_picker/`。
  Future<void> _cleanStaleCaches() async {
    try {
      final tmp = await getTemporaryDirectory();
      // `imports/`：content:// 复制进来的整份视频；
      // `work/`：修复中间产物 / WebDAV 探针文件。上次会话崩溃时可能留下
      // 几 GB 的半成品，启动时任务列表还没恢复，直接清掉是安全的。
      _deleteContents(Directory('${tmp.path}/imports'));
      _deleteContents(Directory('${tmp.path}/work'));
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
