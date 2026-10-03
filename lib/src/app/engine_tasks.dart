import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../engine/engine.dart';
import '../webdav/prefetch.dart';

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

/// 在后台 Isolate 中检测「预取数据」的只读来源（Android SAF：不整份复制）。
Future<InspectReport> inspectPrefetchedInIsolate(
  int size,
  List<({int start, Uint8List bytes})> ranges, {
  required int thresholdBytes,
}) {
  return Isolate.run(() {
    final input = PrefetchedSeekableInput(
      size: size,
      ranges: [for (final r in ranges) PrefetchRange(r.start, r.bytes)],
    );
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

/// 桌面端目录列举结果（[skipped] 为因权限等原因被跳过的子目录数）。
typedef VideoFolderListing = ({
  List<({String path, String rel, int size, int modifiedMs})> files,
  int skipped,
});

/// 是否参与处理的视频扩展名。
bool isVideoFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  final ext = name.substring(dot + 1).toLowerCase();
  return ext == 'mp4' || ext == 'm4v' || ext == 'mov';
}

/// 桌面端：递归列举目录下的视频文件（**同步实现，须在后台 Isolate 中调用**）。
///
/// 与 `listSync(recursive: true)` 的差别：逐个目录列举并容忍失败 ——
/// Windows 上 `System Volume Information`、junction、网络盘等会抛 `errno = 5`，
/// 之前会让整个扫描直接失败；现在只跳过并计数。
VideoFolderListing listVideosSync(String rootPath) {
  final files = <({String path, String rel, int size, int modifiedMs})>[];
  var skipped = 0;
  final stack = <Directory>[Directory(rootPath)];
  final rootLen = rootPath.endsWith(Platform.pathSeparator)
      ? rootPath.length
      : rootPath.length + 1;

  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      skipped++;
      continue;
    }
    for (final e in entries) {
      if (e is Directory) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue; // 隐藏目录
        if (name.toLowerCase() == 'system volume information') continue;
        stack.add(e);
      } else if (e is File) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (!isVideoFileName(name)) continue;
        int size;
        int modifiedMs;
        try {
          size = e.lengthSync();
          modifiedMs = e.lastModifiedSync().millisecondsSinceEpoch;
        } catch (_) {
          size = -1;
          modifiedMs = 0;
        }
        files.add((
          path: e.path,
          rel: e.path.length > rootLen ? e.path.substring(rootLen) : name,
          size: size,
          modifiedMs: modifiedMs,
        ));
      }
    }
  }
  return (files: files, skipped: skipped);
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

/// Isolate 入口：同步执行引擎，进度经 SendPort 回传（约 8 次/秒，避免端口刷屏）。
void _repairWorker(_RepairArgs args) {
  final send = args.sendPort;
  SeekableInput? input;
  FileSyncSink? sink;
  var lastSentMs = 0;
  try {
    input = FileSeekableInput(File(args.inputPath));
    final outFile = File(args.outputPath);
    // 输出目录可能还不存在（默认输出目录 / 用户刚选的目录）→ 先建出来
    outFile.parent.createSync(recursive: true);
    sink = FileSyncSink(outFile.openSync(mode: FileMode.write));
    final stats = Mp4Repair.repair(
      input,
      sink,
      onProgress: (done, total) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (done >= total || now - lastSentMs >= 120) {
          lastSentMs = now;
          send.send({'type': 'progress', 'done': done, 'total': total});
        }
      },
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
