import 'dart:io';

import 'package:mp4fix/src/engine/engine.dart';

/// 桌面命令行工具（测试 / PC 批量修复用）。
///
/// 用法：
///   dart run bin/mp4fix_cli.dart <输入.mp4> <输出.mp4>   # 无损重排修复
///   dart run bin/mp4fix_cli.dart --inspect <文件.mp4>     # 只做健康检测
void main(List<String> args) {
  if (args.isEmpty) {
    _usage();
    exit(1);
  }

  if (args.first == '--inspect' || args.first == '-i') {
    if (args.length < 2) _usage();
    _inspect(File(args[1]));
    return;
  }

  if (args.length < 2) _usage();
  _repair(File(args[0]), File(args[1]));
}

void _usage() {
  stderr
    ..writeln('用法:')
    ..writeln('  mp4fix_cli <输入.mp4> <输出.mp4>   无损重排修复')
    ..writeln('  mp4fix_cli --inspect <文件.mp4>     健康检测');
}

void _inspect(File file) {
  if (!file.existsSync()) {
    stderr.writeln('文件不存在: ${file.path}');
    exit(2);
  }
  final input = FileSeekableInput(file);
  try {
    final r = Mp4Inspect.inspect(input);
    stdout
      ..writeln('文件: ${file.path}')
      ..writeln('大小: ${formatBytes(r.fileSize)}')
      ..writeln('状态: ${_healthText(r.health)}')
      ..writeln('详情: ${r.detail}')
      ..writeln('轨道: ${r.trackCount}（视频样本 ${r.videoSamples} / 音频样本 ${r.audioSamples}）');
  } finally {
    input.close();
  }
}

String _healthText(Mp4Health h) => switch (h) {
      Mp4Health.ok => '正常',
      Mp4Health.needsReinterleave => '需重排',
      Mp4Health.optimizable => '可优化（缺 moov 前置）',
      Mp4Health.unsupported => '不支持（分片等）',
      Mp4Health.corrupt => '损坏',
    };

void _repair(File inFile, File outFile) {
  if (!inFile.existsSync()) {
    stderr.writeln('输入文件不存在: ${inFile.path}');
    exit(3);
  }
  final input = FileSeekableInput(inFile);
  final sink = FileSyncSink(outFile.openSync(mode: FileMode.write));
  final t0 = DateTime.now();
  var lastPct = -1;
  try {
    final stats = Mp4Repair.repair(input, sink, onProgress: (p, total) {
      final pct = total > 0 ? (p * 100 ~/ total) : 0;
      if (pct != lastPct) {
        lastPct = pct;
        stdout.write('\r进度 $pct%');
      }
    });
    stdout.writeln();
    final ms = DateTime.now().difference(t0).inMilliseconds;
    stdout.writeln(
      '完成: 轨道=${stats.trackCount} 输出块=${stats.outputChunks} '
      'moov=${stats.moovBytes}B co64=${stats.usedCo64} '
      '输出=${formatBytes(stats.outputBytes)} 用时=${(ms / 1000).toStringAsFixed(1)}s',
    );
  } catch (e) {
    stdout.writeln();
    stderr.writeln('失败: $e');
    exitCode = 4;
  } finally {
    sink.close();
    input.close();
  }
}
