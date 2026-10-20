import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/app_controller.dart';
import 'package:mp4fix/src/app/models.dart';
import 'package:mp4fix/src/engine/engine.dart';
import 'package:mp4fix/src/webdav/webdav.dart';

import 'support/test_dav_server.dart';

/// 记录「客户端侧同时在途的请求数」。
///
/// 不在服务端统计：服务端把响应写完后还要跑 finally，客户端已经开始下一个
/// 请求了，会把严格串行误判成 2 个并发。
class _CountingClient extends WebDavClient {
  _CountingClient(super.baseUrl);

  int _active = 0;
  int maxActive = 0;

  Future<T> _track<T>(Future<T> Function() task) async {
    _active++;
    if (_active > maxActive) maxActive = _active;
    try {
      return await task();
    } finally {
      _active--;
    }
  }

  @override
  Future<int> download(
    String url,
    File dest, {
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) =>
      _track(() => super.download(
            url,
            dest,
            onProgress: onProgress,
            isCancelled: isCancelled,
          ));

  @override
  Future<Uint8List> getRange(String url, int start, int endInclusive) =>
      _track(() => super.getRange(url, start, endInclusive));
}

/// 并行流水线的端到端回归。
///
/// 单元测试（`parallel_test.dart`）只能证明「窗口确实限制在 N 个」；
/// 这里验证**并发之后结果仍然完整正确**：
///  - WebDAV 扫描 6 个文件（分两层目录）一个不少；
///  - 并行修复后每个文件都产出自己的副本，不互相覆盖；
///  - 本地文件夹并行修复同样全部落位；
///  - 取消标记从第一个文件起就生效（不应先「热身」修几个）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;
  late Directory cache;
  late TestDavServer server;

  setUp(() async {
    // flutter_test 默认拦截所有 HTTP（返回 400）；这里要连本地迷你 DAV 服务器
    HttpOverrides.global = null;
    root = Directory.systemTemp.createTempSync('mp4fix-parallel-dav');
    cache = Directory.systemTemp.createTempSync('mp4fix-parallel-cache');
    Directory('${root.path}/sub').createSync(recursive: true);
    for (var i = 0; i < 6; i++) {
      final dir = i.isEven ? root.path : '${root.path}/sub';
      File('test/fixtures/bad_interleave.mp4')
          .copySync('$dir/bad$i.mp4');
    }
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

  test('WebDAV 并行扫描：6 个文件（含子目录）全部检测到且分类一致', () async {
    final client = WebDavClient(server.baseUrl);
    try {
      final items = await WebDavScanner(
        client,
        threshold: 20000,
        fileConcurrency: 4,
      ).scan(server.baseUrl, tempDir: cache);

      expect(items, hasLength(6));
      expect(
        items.every((it) => it.error == null),
        isTrue,
        reason: items.map((it) => '${it.path}: ${it.error}').join('\n'),
      );
      expect(
        items.every((it) => it.report?.health == Mp4Health.needsReinterleave),
        isTrue,
      );
      expect(
        items.map((it) => it.path).toSet(),
        {
          'bad0.mp4',
          'bad2.mp4',
          'bad4.mp4',
          'sub/bad1.mp4',
          'sub/bad3.mp4',
          'sub/bad5.mp4',
        },
        reason: '每个文件都应恰好出现一次',
      );
    } finally {
      client.close();
    }
  });

  test('WebDAV 并行扫描：一开始就取消 → 不产生任何条目', () async {
    final client = WebDavClient(server.baseUrl);
    try {
      final items = await WebDavScanner(client, fileConcurrency: 4).scan(
        server.baseUrl,
        tempDir: cache,
        isCancelled: () => true,
      );
      expect(items, isEmpty);
    } finally {
      client.close();
    }
  });

  test('WebDAV 并行扫描：请求确实同时在途（不是伪并行）', () async {
    // 用「不支持 Range」的服务器：每个文件先探测 1 次、再整档下载 1 次，
    // 请求与文件一一对应 —— 服务端看到的最大并发数就直接反映文件级并行度。
    // （支持 Range 的路径里，单个文件的 moov 分块本身也会并发，测不出文件级。）
    final slow = await TestDavServer.start(
      root,
      latency: const Duration(milliseconds: 15),
      rangeEnabled: false,
    );
    final client = _CountingClient(slow.baseUrl);
    try {
      await WebDavScanner(
        client,
        threshold: 20000,
        fileConcurrency: 1,
      ).scan(slow.baseUrl, tempDir: cache);
      expect(
        client.maxActive,
        1,
        reason: 'fileConcurrency=1 时必须严格串行（旧行为）',
      );

      client.maxActive = 0;
      await WebDavScanner(
        client,
        threshold: 20000,
        fileConcurrency: 4,
      ).scan(slow.baseUrl, tempDir: cache);
      expect(
        client.maxActive,
        greaterThan(1),
        reason: 'fileConcurrency=4 时请求应真的叠起来，否则并行只是写在注释里',
      );
    } finally {
      client.close();
      await slow.close();
    }
  });

  test('WebDAV 并行修复：每个文件都产出自己的副本，任务全部成功', () async {
    final c = AppController();
    c.settings.webdav.host = server.baseUrl;
    c.settings.webdav.port = '';
    c.settings.webdav.path = '';
    c.settings.parallelism = 3;
    // 夹具的错位只有几十 KB；默认 4MB 阈值会判成「正常」
    c.settings.thresholdMb = 0;
    c.settings.thresholdSeconds = 0;

    await c.scanWebDav(fixAfterScan: false);
    expect(c.jobsOf(JobSource.webdav), hasLength(6));

    await c.fixWebDavJobs(uploadCopies: true);

    final jobs = c.jobsOf(JobSource.webdav);
    expect(
      jobs.map((j) => j.status).toSet(),
      {JobStatus.uploaded},
      reason: jobs.map((j) => '${j.name}: ${j.message}').join('\n'),
    );
    for (var i = 0; i < 6; i++) {
      final dir = i.isEven ? root.path : '${root.path}/sub';
      expect(
        File('$dir/bad${i}_fixed.mp4').existsSync(),
        isTrue,
        reason: 'bad$i 的副本应落在它自己所在的目录',
      );
    }
    expect(c.lastNotice, contains('修复完成 6 个'));
  });

  test('本地文件夹并行修复：5 个文件全部落位到输出目录', () async {
    final input = Directory('${cache.path}/local-in')..createSync();
    final output = Directory('${cache.path}/local-out')..createSync();
    for (var i = 0; i < 5; i++) {
      File('test/fixtures/bad_interleave.mp4')
          .copySync('${input.path}/clip$i.mp4');
    }

    final c = AppController();
    c.settings.scanInputDirPath = input.path;
    c.settings.outputDirPath = output.path;
    c.settings.parallelism = 3;
    // 夹具的错位只有几十 KB；默认 4MB 阈值会判成「正常」
    c.settings.thresholdMb = 0;
    c.settings.thresholdSeconds = 0;

    await c.scanFolder(fixAfterScan: true);

    final jobs = c.jobsOf(JobSource.folder);
    expect(jobs, hasLength(5));
    expect(
      jobs.map((j) => j.status).toSet(),
      {JobStatus.saved},
      reason: jobs.map((j) => '${j.name}: ${j.message}').join('\n'),
    );
    expect(
      output.listSync().whereType<File>().length,
      5,
      reason: '5 个产物都要在（并行不能互相覆盖 / 漏写）',
    );
    expect(c.lastNotice, contains('修复完成 5 个'));
  });
}
