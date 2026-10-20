import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/app_controller.dart';
import 'package:mp4fix/src/app/models.dart';

import 'support/test_dav_server.dart';

/// WebDAV 重复扫描的回归。
///
/// 事故：v2.7.0 修过「文件夹重复扫描把任务列表翻倍」，但 WebDAV 这侧漏了 ——
/// 同一个目录点两次「仅扫描」，条目变两倍；点「扫描并修复」更糟，同一批文件
/// 各修两遍，产物互相覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late Directory cache;
  late TestDavServer server;

  setUp(() async {
    // flutter_test 默认把所有 HTTP 请求拦成 400；这里要连本地迷你 DAV 服务器，
    // 所以还原成真实的 HttpClient。
    HttpOverrides.global = null;
    root = Directory.systemTemp.createTempSync('mp4fix-dav-rescan');
    cache = Directory.systemTemp.createTempSync('mp4fix-dav-cache');
    File('test/fixtures/good.mp4').copySync('${root.path}/a.mp4');
    File('test/fixtures/bad_interleave.mp4').copySync('${root.path}/b.mp4');
    server = await TestDavServer.start(root);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => cache.path);
  });

  tearDown(() async {
    await server.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  test('同一个目录扫描两次：任务不翻倍，且给出扫描汇总', () async {
    final c = AppController();
    c.settings.webdav.host = server.baseUrl;
    c.settings.webdav.port = '';
    c.settings.webdav.path = '';

    await c.scanWebDav(fixAfterScan: false);
    final first = c.jobsOf(JobSource.webdav).length;
    expect(first, 2, reason: '目录里有两个视频');
    expect(c.lastNotice, contains('扫描完成'), reason: '扫描结束要有汇总');

    await c.scanWebDav(fixAfterScan: false);
    expect(
      c.jobsOf(JobSource.webdav),
      hasLength(first),
      reason: '重复扫描不清旧列表 → 同一批文件出现两遍、被修两遍',
    );
  });
}
