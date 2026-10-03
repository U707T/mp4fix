import 'dart:io';

import '../engine/engine.dart';
import 'webdav_client.dart';
import 'webdav_scanner.dart';

/// 单个文件的修复结果。
class FixResult {
  const FixResult({
    required this.ok,
    required this.cancelled,
    required this.message,
    this.remoteName,
    this.bytesWritten = 0,
  });

  final bool ok;
  final bool cancelled;
  final String message;

  /// 上传到服务器的新文件名（上传模式成功时）/ 本地保存的文件名（只读模式）。
  final String? remoteName;

  /// 修复产物的字节数（只读模式用来校验本地文件）。
  final int bytesWritten;

  @override
  String toString() => 'FixResult(ok=$ok, cancelled=$cancelled, $message)';
}

/// 阶段 / 进度回调：`('下载中', 0.42)`。
typedef FixPhaseCallback = void Function(String phase, double progress);

/// 修复执行器：把本地文件 [input] 无损重排为 [output]。
///
/// 默认实现直接调用同步引擎（CLI / 测试）；GUI 层应传入"在后台 Isolate 执行"
/// 的实现，避免修复大文件时卡住界面。
typedef WebDavRepairRunner =
    Future<void> Function({
      required File input,
      required File output,
      void Function(int done, int total)? onProgress,
      bool Function()? isCancelled,
    });

/// "下载 → 无损重排修复 → 上传副本（原名_fixed.mp4）" 的完整流水线。
///
/// 另提供只读用法 [fixToFile]：只下载，修复结果写到你给定的文件，
/// 服务器不做任何写入，适合"下载到本地 → 自己手动上传"的流程。
class WebDavFixer {
  WebDavFixer(this.client, {required this.cacheDir, WebDavRepairRunner? repair})
    : _repair = repair ?? runRepairSync;

  final WebDavClient client;
  final Directory cacheDir;
  final WebDavRepairRunner _repair;

  static int _counter = 0;

  /// 默认修复执行器：直接调用同步引擎（会阻塞调用线程）。
  static Future<void> runRepairSync({
    required File input,
    required File output,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final seekable = FileSeekableInput(input);
    final sink = FileSyncSink(output.openSync(mode: FileMode.write));
    try {
      Mp4Repair.repair(
        seekable,
        sink,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    } finally {
      sink.close();
      seekable.close();
    }
  }

  File _tempFile(String prefix) => File(
    '${cacheDir.path}/$prefix-${DateTime.now().microsecondsSinceEpoch}'
    '-${_counter++}.mp4',
  );

  /// 只读模式：下载原件 → 本地无损重排 → 写入 [output] 文件。
  ///
  /// **不向服务器写任何东西**（不上传、不移动、不删除），只有 GET / PROPFIND。
  Future<FixResult> fixToFile(
    ScanItem item,
    File output, {
    FixPhaseCallback? onPhase,
    bool Function()? isCancelled,
  }) async {
    cacheDir.createSync(recursive: true);
    final downloadFile = _tempFile('dl');
    bool cancelled() => isCancelled?.call() ?? false;
    try {
      onPhase?.call('下载中', 0);
      await client.download(
        item.url,
        downloadFile,
        onProgress: (done, total) {
          if (total > 0) onPhase?.call('下载中', done / total * 0.7);
        },
      );
      if (cancelled()) return _cancelledResult();

      onPhase?.call('修复中', 0.7);
      output.parent.createSync(recursive: true);
      await _repair(
        input: downloadFile,
        output: output,
        isCancelled: isCancelled,
        onProgress: (done, total) {
          if (total > 0) onPhase?.call('修复中', 0.7 + done / total * 0.3);
        },
      );
      if (cancelled()) return _cancelledResult();

      onPhase?.call('完成', 1);
      return FixResult(
        ok: true,
        cancelled: false,
        message: '已修复',
        bytesWritten: output.existsSync() ? output.lengthSync() : 0,
      );
    } on RepairCancelledException {
      return _cancelledResult();
    } catch (e) {
      return FixResult(
        ok: false,
        cancelled: false,
        message: errorMessage(e),
      );
    } finally {
      if (downloadFile.existsSync()) downloadFile.deleteSync();
    }
  }

  /// 通用输出汇版本（同步引擎直接写出，适合测试 / 一次性写入）。
  Future<FixResult> fixToSink(
    ScanItem item,
    SyncSink output, {
    FixPhaseCallback? onPhase,
    bool Function()? isCancelled,
  }) async {
    cacheDir.createSync(recursive: true);
    final downloadFile = _tempFile('dl');
    bool cancelled() => isCancelled?.call() ?? false;
    try {
      onPhase?.call('下载中', 0);
      await client.download(
        item.url,
        downloadFile,
        onProgress: (done, total) {
          if (total > 0) onPhase?.call('下载中', done / total * 0.7);
        },
      );
      if (cancelled()) return _cancelledResult();

      onPhase?.call('修复中', 0.7);
      final input = FileSeekableInput(downloadFile);
      final RepairStats stats;
      try {
        stats = Mp4Repair.repair(
          input,
          output,
          isCancelled: isCancelled,
          onProgress: (p, total) {
            if (total > 0) onPhase?.call('修复中', 0.7 + p / total * 0.3);
          },
        );
      } finally {
        input.close();
      }
      if (cancelled()) return _cancelledResult();

      onPhase?.call('完成', 1);
      return FixResult(
        ok: true,
        cancelled: false,
        message: '已修复',
        bytesWritten: stats.outputBytes,
      );
    } on RepairCancelledException {
      return _cancelledResult();
    } catch (e) {
      return FixResult(
        ok: false,
        cancelled: false,
        message: errorMessage(e),
      );
    } finally {
      if (downloadFile.existsSync()) downloadFile.deleteSync();
    }
  }

  /// 上传副本模式：下载 → 修复 → 上传「原名_fixed.mp4」（重名自动加序号），
  /// 上传后校验服务器上的文件大小。原文件不动。
  ///
  /// [copyName] 可指定副本文件名（设置里的命名规则）；为空时用 `原名_fixed.ext`。
  Future<FixResult> fix(
    ScanItem item, {
    FixPhaseCallback? onPhase,
    bool Function()? isCancelled,
    String? copyName,
  }) async {
    cacheDir.createSync(recursive: true);
    final downloadFile = _tempFile('dl');
    final fixedFile = _tempFile('fx');
    bool cancelled() => isCancelled?.call() ?? false;
    String? uploadingTarget;
    try {
      // 1）下载原件
      onPhase?.call('下载中', 0);
      await client.download(
        item.url,
        downloadFile,
        onProgress: (done, total) {
          if (total > 0) onPhase?.call('下载中', done / total * 0.45);
        },
      );
      if (cancelled()) return _cancelledResult();

      // 2）无损修复
      onPhase?.call('修复中', 0.45);
      await _repair(
        input: downloadFile,
        output: fixedFile,
        isCancelled: isCancelled,
        onProgress: (done, total) {
          if (total > 0) onPhase?.call('修复中', 0.45 + done / total * 0.3);
        },
      );
      if (cancelled()) return _cancelledResult();

      // 3）上传副本（唯一命名：默认 原名_fixed.mp4；重名自动加序号）
      onPhase?.call('上传中', 0.75);
      final fileName = client.fileNameOf(item.url);
      final dot = fileName.lastIndexOf('.');
      final base = dot > 0 ? fileName.substring(0, dot) : fileName;
      final ext = dot > 0 ? fileName.substring(dot + 1) : 'mp4';
      final wanted = copyName ?? '${base}_fixed.$ext';
      var target = client.sibling(item.url, wanted);
      var n = 2;
      while (await client.exists(target) && n <= 50) {
        target = client.sibling(item.url, _withSequence(wanted, n));
        n++;
      }
      if (await client.exists(target)) {
        return const FixResult(
          ok: false,
          cancelled: false,
          message: '无法生成唯一的输出文件名',
        );
      }
      uploadingTarget = target;
      await client.upload(
        target,
        fixedFile,
        onProgress: (done, total) {
          if (total > 0) onPhase?.call('上传中', 0.75 + done / total * 0.2);
        },
      );
      if (cancelled()) {
        await _quietDelete(target);
        return _cancelledResult();
      }

      // 4）校验
      onPhase?.call('校验中', 0.97);
      final st = await client.stat(target);
      if (st == null ||
          (st.size >= 0 && st.size != fixedFile.lengthSync())) {
        await _quietDelete(target);
        return const FixResult(
          ok: false,
          cancelled: false,
          message: '上传后校验失败（大小不一致）',
        );
      }
      onPhase?.call('完成', 1);
      return FixResult(
        ok: true,
        cancelled: false,
        message: '已修复',
        remoteName: client.fileNameOf(target),
      );
    } on RepairCancelledException {
      return _cancelledResult();
    } catch (e) {
      // 上传中途失败时清理服务器上的半成品
      if (uploadingTarget != null && !cancelled()) {
        await _quietDelete(uploadingTarget);
      }
      return FixResult(
        ok: false,
        cancelled: false,
        message: errorMessage(e),
      );
    } finally {
      if (downloadFile.existsSync()) downloadFile.deleteSync();
      if (fixedFile.existsSync()) fixedFile.deleteSync();
    }
  }

  static FixResult _cancelledResult() => const FixResult(
    ok: false,
    cancelled: true,
    message: '已取消',
  );

  /// 重名时的退让命名：`a_fixed.mp4` + 2 → `a_fixed_2.mp4`。
  static String _withSequence(String fileName, int n) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) return '${fileName}_$n';
    return '${fileName.substring(0, dot)}_$n${fileName.substring(dot)}';
  }

  Future<void> _quietDelete(String url) async {
    try {
      await client.delete(url);
    } catch (_) {
      // 尽力而为
    }
  }
}
