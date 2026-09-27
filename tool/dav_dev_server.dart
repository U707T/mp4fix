import 'dart:io';

import '../test/support/test_dav_server.dart';

/// 开发 / 联调用的迷你 WebDAV 服务器：把本地目录以 WebDAV 暴露出来。
///
/// 用法：
///   dart run tool/dav_dev_server.dart <目录> [端口，默认 8080] [--user u] [--pass p]
///
/// 之后可用 CLI 联调：
///   dart run bin/mp4fix_cli.dart --dav-scan http://127.0.0.1:8080
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/dav_dev_server.dart <目录> [端口] '
        '[--user u] [--pass p] [--no-range]');
    exit(1);
  }
  final root = Directory(args.first);
  if (!root.existsSync()) {
    stderr.writeln('目录不存在: ${root.path}');
    exit(2);
  }
  var port = 8080;
  String? user;
  String? pass;
  var range = true;
  for (var i = 1; i < args.length; i++) {
    final a = args[i];
    if (a == '--user' && i + 1 < args.length) {
      user = args[++i];
    } else if (a == '--pass' && i + 1 < args.length) {
      pass = args[++i];
    } else if (a == '--no-range') {
      range = false;
    } else {
      port = int.tryParse(a) ?? port;
    }
  }

  final server = await TestDavServer.start(
    root,
    user: user,
    pass: pass,
    rangeEnabled: range,
    port: port,
  );
  stdout.writeln('WebDAV 服务器已启动: ${server.baseUrl}'
      '（根目录: ${root.path}${range ? '' : '，已禁用 Range'}）');
  stdout.writeln('按 Ctrl+C 退出。');

  await ProcessSignal.sigint.watch().first;
  await server.close();
  stdout.writeln('已退出。');
}
