import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../engine/engine.dart';

/// 在后台 Isolate 中检测本地文件（不阻塞 UI）。
Future<InspectReport> inspectFileInIsolate(
  String path, {
  required int thresholdBytes,
}) {
  return Isolate.run(() {
    final input = FileSeekableInput(File(path));
    try {
      return Mp4Inspect.inspect(
        input,
        interleaveThresholdBytes: thresholdBytes,
      );
    } finally {
      input.close();
    }
  });
}

/// 后台修复任务的句柄：可监听进度、等待结果、取消。
class RepairTask {
  RepairTask._(this._isolate, this._port, this._completer);

  final Isolate _isolate;
  final ReceivePort _port;
  final Completer<RepairStats> _completer;
  bool _cancelled = false;
  bool get cancelled => _cancelled;

  /// 修复结果（失败时抛出 [RepairException] / [RepairCancelledException]）。
  Future<RepairStats> get done => _completer.future;

  /// 立即取消（杀死 Isolate；半成品文件由调用方清理）。
  void cancel() {
    _cancelled = true;
    _isolate.kill(priority: Isolate.immediate);
    if (!_completer.isCompleted) {
      _completer.completeError(RepairCancelledException());
    }
    _port.close();
  }

  /// 在后台 Isolate 中把 [inputPath] 修复到 [outputPath]。
  static Future<RepairTask> start({
    required String inputPath,
    required String outputPath,
    void Function(int done, int total)? onProgress,
  }) async {
    final port = ReceivePort();
    final isolate = await Isolate.spawn(
      _repairWorker,
      _RepairArgs(inputPath, outputPath, port.sendPort),
    );
    final completer = Completer<RepairStats>();
    final task = RepairTask._(isolate, port, completer);

    port.listen((message) {
      if (message is! Map) return;
      switch (message['type']) {
        case 'progress':
          onProgress?.call(message['done'] as int, message['total'] as int);
        case 'done':
          if (!completer.isCompleted) {
            completer.complete(message['stats'] as RepairStats);
          }
          port.close();
          isolate.kill(priority: Isolate.beforeNextEvent);
        case 'error':
          if (!completer.isCompleted) {
            completer.completeError(
              (message['cancelled'] as bool? ?? false)
                  ? RepairCancelledException()
                  : RepairException(message['message'] as String? ?? '修复失败'),
            );
          }
          port.close();
          isolate.kill(priority: Isolate.beforeNextEvent);
      }
    });
    return task;
  }
}

class _RepairArgs {
  const _RepairArgs(this.inputPath, this.outputPath, this.sendPort);

  final String inputPath;
  final String outputPath;
  final SendPort sendPort;
}

/// Isolate 入口：同步执行引擎，进度经 SendPort 回传。
void _repairWorker(_RepairArgs args) {
  final send = args.sendPort;
  SeekableInput? input;
  FileSyncSink? sink;
  try {
    input = FileSeekableInput(File(args.inputPath));
    sink = FileSyncSink(File(args.outputPath).openSync(mode: FileMode.write));
    final stats = Mp4Repair.repair(
      input,
      sink,
      onProgress: (done, total) =>
          send.send({'type': 'progress', 'done': done, 'total': total}),
    );
    sink.close();
    sink = null;
    input.close();
    input = null;
    send.send({'type': 'done', 'stats': stats});
  } catch (e) {
    try {
      sink?.close();
    } catch (_) {}
    try {
      input?.close();
    } catch (_) {}
    send.send({
      'type': 'error',
      'message': errorMessage(e),
      'cancelled': e is RepairCancelledException,
    });
  }
}
