import 'dart:io';

import 'package:mp4fix/src/engine/engine.dart';
import 'package:mp4fix/src/webdav/webdav.dart';

/// 桌面命令行工具（修复 / 检测 / WebDAV 扫描与修复）。
///
/// 用法：
///   `dart run bin/mp4fix_cli.dart --inspect 文件.mp4`
///   `dart run bin/mp4fix_cli.dart 输入.mp4 输出.mp4`
///   `dart run bin/mp4fix_cli.dart --dav-scan URL [--user u --pass p --threshold 4 --insecure]`
///   `dart run bin/mp4fix_cli.dart --dav-fix URL [同一组选项]`（扫描后上传「原名_fixed.mp4」副本）
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(1);
  }

  final opts = _Options.parse(args);

  switch (args.first) {
    case '--inspect':
    case '-i':
      final path = opts.positional.isEmpty ? null : opts.positional.first;
      if (path == null) _usage();
      _inspect(File(path!));
      return;
    case '--dav-scan':
      final url = opts.positional.isEmpty ? null : opts.positional.first;
      if (url == null) _usage();
      final code = await _davScan(url!, opts);
      exit(code);
    case '--dav-fix':
      final url = opts.positional.isEmpty ? null : opts.positional.first;
      if (url == null) _usage();
      final code = await _davFix(url!, opts);
      exit(code);
    case '--help':
    case '-h':
      _usage();
      return;
    default:
      if (opts.positional.length < 2) _usage();
      _repair(File(opts.positional[0]), File(opts.positional[1]));
  }
}

void _usage() {
  stdout
    ..writeln('MP4 无损修复器 CLI')
    ..writeln()
    ..writeln('用法:')
    ..writeln('  mp4fix_cli --inspect <文件.mp4>          本地健康检测')
    ..writeln('  mp4fix_cli <输入.mp4> <输出.mp4>          本地无损修复')
    ..writeln('  mp4fix_cli --dav-scan <URL>              扫描 WebDAV 目录（只读）')
    ..writeln('  mp4fix_cli --dav-fix  <URL>              扫描并上传修复副本')
    ..writeln()
    ..writeln('选项:')
    ..writeln('  --user <用户名>  --pass <密码>  --threshold <MB，默认 4，可小数>')
    ..writeln('  --insecure（允许自签名证书）  --include-optimizable（含"可优化"）');
}

class _Options {
  _Options(this.positional, this.user, this.pass, this.thresholdMb,
      this.insecure, this.includeOptimizable);

  final List<String> positional;
  final String? user;
  final String? pass;
  final double thresholdMb;
  final bool insecure;
  final bool includeOptimizable;

  static _Options parse(List<String> args) {
    final positional = <String>[];
    String? user;
    String? pass;
    var threshold = 4.0;
    var insecure = false;
    var includeOptimizable = false;
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      switch (a) {
        case '--user':
          if (i + 1 < args.length) user = args[++i];
        case '--pass':
          if (i + 1 < args.length) pass = args[++i];
        case '--threshold':
          if (i + 1 < args.length) {
            threshold = double.tryParse(args[++i]) ?? 4.0;
          }
        case '--insecure':
          insecure = true;
        case '--include-optimizable':
          includeOptimizable = true;
        default:
          if (!a.startsWith('--')) positional.add(a);
      }
    }
    return _Options(
        positional, user, pass, threshold, insecure, includeOptimizable);
  }

  WebDavClient client(String rootUrl) => WebDavClient(
        rootUrl,
        username: user ?? '',
        password: pass ?? '',
        allowInsecureTls: insecure,
      );

  int get thresholdBytes => (thresholdMb * 1024 * 1024).round();
}

String _healthText(Mp4Health h) => switch (h) {
      Mp4Health.ok => '正常',
      Mp4Health.needsReinterleave => '需重排',
      Mp4Health.optimizable => '可优化',
      Mp4Health.unsupported => '不支持',
      Mp4Health.corrupt => '损坏',
    };

// ---------------------------------------------------------------- 本地

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

// ---------------------------------------------------------------- WebDAV

Future<int> _davScan(String url, _Options opts) async {
  final client = opts.client(url);
  final cacheDir = Directory.systemTemp.createTempSync('mp4fix-dav');
  try {
    final scanner = WebDavScanner(client, threshold: opts.thresholdBytes);
    stdout.writeln('扫描中: $url（阈值 ${opts.thresholdMb} MB）…');
    final items = await scanner.scan(
      url,
      tempDir: cacheDir,
      onFile: (item) {
        final status = item.report != null
            ? _healthText(item.report!.health)
            : '读取失败';
        stdout.writeln('  [$status] ${item.path}'
            '${item.error != null ? ' — ${item.error}' : ''}');
      },
    );
    final need = items.where((i) => i.needsFix).length;
    stdout.writeln('完成: 共 ${items.length} 个视频，需重排 $need 个');
    return 0;
  } catch (e) {
    stderr.writeln('失败: $e');
    return 5;
  } finally {
    client.close();
    cacheDir.deleteSync(recursive: true);
  }
}

Future<int> _davFix(String url, _Options opts) async {
  final client = opts.client(url);
  final cacheDir = Directory.systemTemp.createTempSync('mp4fix-dav');
  try {
    final scanner = WebDavScanner(client, threshold: opts.thresholdBytes);
    stdout.writeln('扫描中: $url …');
    final items = await scanner.scan(url, tempDir: cacheDir);
    final todo = items
        .where((i) =>
            i.needsFix ||
            (opts.includeOptimizable &&
                i.report?.health == Mp4Health.optimizable))
        .toList();
    stdout.writeln('共 ${items.length} 个视频，待处理 ${todo.length} 个');

    final fixer = WebDavFixer(client, cacheDir: cacheDir);
    var ok = 0;
    var failed = 0;
    for (var i = 0; i < todo.length; i++) {
      final item = todo[i];
      stdout.writeln('修复 ${i + 1}/${todo.length}: ${item.path}');
      final result = await fixer.fix(
        item,
        onPhase: (phase, progress) {
          stdout.write('\r  $phase ${(progress * 100).toInt()}%   ');
        },
      );
      stdout.writeln();
      if (result.ok) {
        ok++;
        stdout.writeln('  ✓ 已修复 → ${result.remoteName}');
      } else {
        failed++;
        stdout.writeln('  ✗ ${result.message}');
      }
    }
    stdout.writeln('完成: 成功 $ok，失败 $failed');
    return failed > 0 ? 6 : 0;
  } catch (e) {
    stderr.writeln('失败: $e');
    return 5;
  } finally {
    client.close();
    cacheDir.deleteSync(recursive: true);
  }
}
