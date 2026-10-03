import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/engine/engine.dart';
import 'package:mp4fix/src/webdav/webdav.dart';

import 'support/test_dav_server.dart';

/// WebDAV 客户端 / 远程检测 / 扫描 / 修复的端到端测试（对本地迷你 WebDAV 服务器）。
///
/// 夹具目录：
///   library/good.mp4                     → OK
///   library/bad.mp4（交错被打乱）        → NEEDS_REINTERLEAVE（阈值 20KB 下）
///   library/note.txt                     → 非视频，应被跳过
///   library/sub dir 中文/truncated.mp4   → CORRUPT（测试空格与中文路径）
void main() {
  late Directory tmpRoot;
  late Directory cacheDir;
  late TestDavServer server;
  late WebDavClient client;

  File fixture(String name) => File('test/fixtures/$name');

  setUp(() async {
    tmpRoot = Directory.systemTemp.createTempSync('dav-root');
    cacheDir = Directory.systemTemp.createTempSync('dav-cache');
    Directory('${tmpRoot.path}/library').createSync(recursive: true);
    fixture('good.mp4').copySync('${tmpRoot.path}/library/good.mp4');
    fixture('bad_interleave.mp4').copySync('${tmpRoot.path}/library/bad.mp4');
    Directory('${tmpRoot.path}/library/sub dir 中文')
        .createSync(recursive: true);
    fixture('truncated.mp4')
        .copySync('${tmpRoot.path}/library/sub dir 中文/truncated.mp4');
    File('${tmpRoot.path}/library/note.txt').writeAsStringSync('hello');
    server = await TestDavServer.start(tmpRoot);
    client = WebDavClient(server.baseUrl);
  });

  tearDown(() async {
    client.close();
    await server.close();
    if (tmpRoot.existsSync()) tmpRoot.deleteSync(recursive: true);
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  /// 对整个 library 目录做一次扫描（阈值 20KB：小夹具也能拉开“需重排”）。
  Future<List<ScanItem>> scanAll(TestDavServer s, WebDavClient c) =>
      WebDavScanner(c, threshold: 20000).scan(
        '${s.baseUrl}/library',
        tempDir: cacheDir,
      );

  // ---------------------------------------------------------------- 客户端

  test('list 返回解码后的条目名（含中文与空格）', () async {
    final entries = await client.list('${server.baseUrl}/library/');
    final names = entries.map((e) => e.name).toList();
    expect(names, contains('good.mp4'));
    expect(names, contains('bad.mp4'));
    expect(names, contains('note.txt'));
    expect(names, contains('sub dir 中文'), reason: '$names');

    final subDir = entries.firstWhere((e) => e.name == 'sub dir 中文');
    expect(subDir.isDirectory, isTrue);

    final good = entries.firstWhere((e) => e.name == 'good.mp4');
    expect(good.size, fixture('good.mp4').lengthSync());
  });

  test('download 与源文件字节一致', () async {
    final dest = File('${cacheDir.path}/dl.mp4');
    await client.download('${server.baseUrl}/library/good.mp4', dest);
    expect(dest.readAsBytesSync(), fixture('good.mp4').readAsBytesSync());
  });

  test('upload / move / delete', () async {
    final up = File('${cacheDir.path}/up.mp4');
    fixture('good.mp4').copySync(up.path);

    await client.upload('${server.baseUrl}/library/up.mp4', up);
    expect(File('${tmpRoot.path}/library/up.mp4').existsSync(), isTrue);
    expect(await client.exists('${server.baseUrl}/library/up.mp4'), isTrue);

    await client.move('${server.baseUrl}/library/up.mp4',
        '${server.baseUrl}/library/up2.mp4');
    expect(File('${tmpRoot.path}/library/up.mp4').existsSync(), isFalse);
    expect(File('${tmpRoot.path}/library/up2.mp4').existsSync(), isTrue);

    await client.delete('${server.baseUrl}/library/up2.mp4');
    expect(File('${tmpRoot.path}/library/up2.mp4').existsSync(), isFalse);
    expect(await client.exists('${server.baseUrl}/library/up2.mp4'), isFalse);
  });

  test('Range 读取与源文件一致', () async {
    final url = '${server.baseUrl}/library/good.mp4';
    expect(await client.supportsRange(url), isTrue);
    final local = fixture('good.mp4').readAsBytesSync();
    final part = await client.getRange(url, 100, 357);
    expect(part, local.sublist(100, 358));
  });

  test('远程预取检测与本地检测结果一致（且流量远小于整档）', () async {
    final url = '${server.baseUrl}/library/good.mp4';
    final size = fixture('good.mp4').lengthSync();
    final input = await prefetchForInspect(client, url, fileSize: size);
    late final InspectReport remote;
    try {
      remote = Mp4Inspect.inspect(input, interleaveThresholdBytes: 20000);
      expect(input.prefetchedBytes, lessThan(size),
          reason: '预取只应包含盒头 + moov，不应整档下载');
    } finally {
      input.close();
    }

    final localInput = FileSeekableInput(fixture('good.mp4'));
    late final InspectReport local;
    try {
      local = Mp4Inspect.inspect(localInput, interleaveThresholdBytes: 20000);
    } finally {
      localInput.close();
    }

    expect(remote.health, local.health);
    expect(remote.videoSamples, local.videoSamples);
    expect(remote.audioSamples, local.audioSamples);
    expect(remote.interleaveMaxBytes, local.interleaveMaxBytes);
    expect(remote.interleaveMeanBytes, local.interleaveMeanBytes);
    expect(remote.faststart, local.faststart);
  });

  test('分片 MP4：远程预取检测与本地一致，且可下载修复为健康文件', () async {
    fixture('fragmented.mp4').copySync('${tmpRoot.path}/library/frag.mp4');
    final url = '${server.baseUrl}/library/frag.mp4';
    final size = fixture('fragmented.mp4').lengthSync();

    // 远程预取（盒头 + moov + 各 moof）检测
    final reqBefore = server.requestCount;
    final input = await prefetchForInspect(client, url, fileSize: size);
    final reqs = server.requestCount - reqBefore;
    late final InspectReport remote;
    try {
      remote = Mp4Inspect.inspect(input, interleaveThresholdBytes: 20000);
      expect(input.prefetchedBytes, lessThan(size), reason: '不应整档下载');
      // 窗口化预取：8 个分片的文件应只需个位数请求（此前每个片段要 3 个）
      expect(reqs, lessThan(30), reason: '分片预取请求数 $reqs');
    } finally {
      input.close();
    }

    late final InspectReport local;
    final localInput = FileSeekableInput(fixture('fragmented.mp4'));
    try {
      local = Mp4Inspect.inspect(localInput, interleaveThresholdBytes: 20000);
    } finally {
      localInput.close();
    }

    expect(remote.health, local.health);
    expect(remote.videoSamples, local.videoSamples);
    expect(remote.audioSamples, local.audioSamples);
    expect(remote.interleaveMaxBytes, local.interleaveMaxBytes);
    expect(remote.interleaveMeanBytes, local.interleaveMeanBytes);
    expect(remote.faststart, local.faststart);
    expect(remote.health, Mp4Health.needsReinterleave, reason: remote.detail);

    // 扫描器同样能识别（走远程 Range 预取路径）
    final frag =
        (await scanAll(server, client)).firstWhere((it) => it.path == 'frag.mp4');
    expect(frag.report, isNotNull, reason: frag.error);
    expect(frag.report!.health, Mp4Health.needsReinterleave,
        reason: frag.report!.detail);

    // 下载到本地 → 无损扁平化 → 健康产物（服务器只读）
    final fixer = WebDavFixer(client, cacheDir: cacheDir);
    final out = File('${cacheDir.path}/frag-fixed.mp4');
    final result = await fixer.fixToFile(frag, out);
    expect(result.ok, isTrue, reason: result.message);

    final fixedInput = FileSeekableInput(out);
    try {
      final report =
          Mp4Inspect.inspect(fixedInput, interleaveThresholdBytes: 100000);
      expect(report.health, Mp4Health.ok, reason: report.detail);
      expect(report.faststart, isTrue);
    } finally {
      fixedInput.close();
    }
    expect(File('${tmpRoot.path}/library/frag_fixed.mp4').existsSync(), isFalse,
        reason: '只读模式不应向服务器写入');
  });

  test('Basic 认证：无凭据 401，有凭据可用', () async {
    final secured = await TestDavServer.start(tmpRoot, user: 'u', pass: 'p');
    try {
      final anon = WebDavClient(secured.baseUrl);
      await expectLater(
        anon.list('${secured.baseUrl}/library/'),
        throwsA(
          isA<WebDavException>().having(
            (e) => e.message,
            'message',
            contains('401'),
          ),
        ),
      );
      anon.close();

      final ok = WebDavClient(secured.baseUrl, username: 'u', password: 'p');
      expect(await ok.list('${secured.baseUrl}/library/'), isNotEmpty);
      ok.close();
    } finally {
      await secured.close();
    }
  });

  // ---------------------------------------------------------------- 扫描

  test('扫描分类正确（含中文 / 空格路径）', () async {
    final items = await scanAll(server, client);
    final byPath = {for (final it in items) it.path: it};
    expect(items.length, 3,
        reason: items.map((it) => '${it.path}:${it.report?.health.name ?? it.error}').toString());

    final good = byPath['good.mp4'];
    expect(good?.report, isNotNull, reason: good?.error);
    expect(good!.report!.health, Mp4Health.ok);

    final bad = byPath['bad.mp4'];
    expect(bad?.report, isNotNull, reason: bad?.error);
    expect(bad!.report!.health, Mp4Health.needsReinterleave,
        reason: bad.report!.detail);

    final truncated = byPath['sub dir 中文/truncated.mp4'];
    expect(truncated, isNotNull, reason: '中文/空格路径应被正确扫描');
    expect(truncated!.report, isNotNull, reason: truncated.error);
    expect(truncated.report!.health, Mp4Health.corrupt,
        reason: truncated.report!.detail);
  });

  test('服务器不支持 Range 时自动降级为整档下载检测', () async {
    final noRange = await TestDavServer.start(tmpRoot, rangeEnabled: false);
    try {
      final noRangeClient = WebDavClient(noRange.baseUrl);
      try {
        final items = await scanAll(noRange, noRangeClient);
        final bad = items.firstWhere((it) => it.path == 'bad.mp4');
        expect(bad.report, isNotNull, reason: bad.error);
        expect(bad.report!.health, Mp4Health.needsReinterleave);
      } finally {
        noRangeClient.close();
      }
    } finally {
      await noRange.close();
    }
  });

  // ---------------------------------------------------------------- 修复

  test('上传副本模式：产物与本地修复逐字节一致、原文件不动、重名自动加序号', () async {
    final badItem =
        (await scanAll(server, client)).firstWhere((it) => it.path == 'bad.mp4');
    final fixer = WebDavFixer(client, cacheDir: cacheDir);

    final result = await fixer.fix(badItem);
    expect(result.ok, isTrue, reason: result.message);
    expect(result.remoteName, 'bad_fixed.mp4');

    // 服务器上的 bad_fixed.mp4 应与本地修复结果一致
    final serverFixed = File('${tmpRoot.path}/library/bad_fixed.mp4');
    expect(serverFixed.existsSync(), isTrue);
    final localFixed = File('${cacheDir.path}/local-fixed.mp4');
    try {
      final input = FileSeekableInput(File('${tmpRoot.path}/library/bad.mp4'));
      final sink = FileSyncSink(localFixed.openSync(mode: FileMode.write));
      try {
        Mp4Repair.repair(input, sink);
      } finally {
        sink.close();
        input.close();
      }
      expect(serverFixed.readAsBytesSync(), localFixed.readAsBytesSync(),
          reason: '修复输出应为确定性字节');
    } finally {
      if (localFixed.existsSync()) localFixed.deleteSync();
    }

    // 原文件未被改动
    expect(
      File('${tmpRoot.path}/library/bad.mp4').readAsBytesSync(),
      fixture('bad_interleave.mp4').readAsBytesSync(),
    );

    // 再次修复 → 生成 _fixed_2
    final again = await fixer.fix(badItem);
    expect(again.ok, isTrue, reason: again.message);
    expect(again.remoteName, 'bad_fixed_2.mp4');

    // 缓存目录不残留
    expect(cacheDir.listSync().length, 0);
  });

  test('只读模式：下载到本地（服务器零写入）', () async {
    final badItem =
        (await scanAll(server, client)).firstWhere((it) => it.path == 'bad.mp4');
    final fixer = WebDavFixer(client, cacheDir: cacheDir);
    final out = File('${cacheDir.path}/out.mp4');

    final result = await fixer.fixToFile(badItem, out);
    expect(result.ok, isTrue, reason: result.message);
    expect(result.bytesWritten, out.lengthSync());

    // 产物应为"健康"文件，且服务器上没有任何新增
    final fixedInput = FileSeekableInput(out);
    try {
      final report = Mp4Inspect.inspect(fixedInput, interleaveThresholdBytes: 20000);
      expect(report.health, Mp4Health.ok, reason: report.detail);
    } finally {
      fixedInput.close();
    }
    expect(File('${tmpRoot.path}/library/bad_fixed.mp4').existsSync(), isFalse);
    expect(cacheDir.listSync().length, 1, reason: '仅保留调用方指定的输出文件');
  });

  test('修复截断文件失败且无副作用', () async {
    final item = (await scanAll(server, client))
        .firstWhere((it) => it.path == 'sub dir 中文/truncated.mp4');
    final fixer = WebDavFixer(client, cacheDir: cacheDir);
    final result = await fixer.fix(item);
    expect(result.ok, isFalse);
    expect(result.cancelled, isFalse);
    expect(
      result.message.contains('截断') ||
          result.message.contains('越界') ||
          result.message.contains('损坏'),
      isTrue,
      reason: result.message,
    );
    expect(
      File('${tmpRoot.path}/library/sub dir 中文/truncated_fixed.mp4').existsSync(),
      isFalse,
    );
  });

  test('修复支持取消（不产生副本、不留残留）', () async {
    final item =
        (await scanAll(server, client)).firstWhere((it) => it.path == 'bad.mp4');
    final fixer = WebDavFixer(client, cacheDir: cacheDir);
    final result = await fixer.fix(item, isCancelled: () => true);
    expect(result.cancelled, isTrue);
    expect(result.remoteName, isNull);
    expect(File('${tmpRoot.path}/library/bad_fixed.mp4').existsSync(), isFalse);
    expect(cacheDir.listSync().length, 0);
  });
}
