import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/webdav/webdav.dart';

import 'support/test_dav_server.dart';
import 'support/truncating_server.dart';

/// WebDAV 的 URL 工具与"下载完整性"回归。
void main() {
  group('URL 工具', () {
    test('sanitizeUrl：保留已有 %XX、编码空格与 #（文件名里的 # 不再被当 fragment）', () {
      expect(WebDavClient.sanitizeUrl('/dav/我的 视频/a.mp4'),
          '/dav/%E6%88%91%E7%9A%84%20%E8%A7%86%E9%A2%91/a.mp4');
      expect(WebDavClient.sanitizeUrl('/dav/a%20b.mp4'), '/dav/a%20b.mp4');
      expect(WebDavClient.sanitizeUrl('/dav/a#b.mp4'), '/dav/a%23b.mp4');
      expect(WebDavClient.sanitizeUrl('http://h:5244/dav'), 'http://h:5244/dav');
    });

    test('percentDecode / encodeSegment 互为逆运算（含中文与空格）', () {
      const name = '中文 名称#1.mp4';
      expect(WebDavClient.percentDecode(WebDavClient.encodeSegment(name)), name);
      expect(WebDavClient.percentDecode('a+b'), 'a+b', reason: '+ 不应被当作空格');
    });

    test('fileNameOf / sibling / ensureTrailingSlash / resolve', () {
      final helper = WebDavClient('http://h/dav');
      expect(
        helper.fileNameOf('http://h/dav/%E4%B8%AD%E6%96%87%20x.mp4'),
        '中文 x.mp4',
      );
      expect(
        helper.sibling('http://h/dav/a.mp4', 'b c.mp4'),
        'http://h/dav/b%20c.mp4',
      );
      expect(helper.ensureTrailingSlash('http://h/dav'), 'http://h/dav/');
      helper.close();
      final client = WebDavClient('http://h:5244/dav');
      expect(client.resolve('/dav/sub/b.mp4', 'http://h:5244/dav/x/'),
          'http://h:5244/dav/sub/b.mp4');
      expect(client.root, 'http://h:5244/dav');
    });

    test('root 规范化：补协议 / 去尾斜杠', () {
      expect(WebDavClient('h:5244/dav/').root, 'https://h:5244/dav');
      expect(WebDavClient('http://192.168.1.2:5244/dav//').root,
          'http://192.168.1.2:5244/dav');
      expect(() => WebDavClient('   '), throwsArgumentError);
    });
  });

  group('下载完整性', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dav-trunc'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('服务端声明长度但提前断开：download 抛明确错误（不静默产出截断文件）', () async {
      final bad = await TruncatingServer.start(file: File('test/fixtures/good.mp4'));
      final client = WebDavClient(bad.baseUrl);
      try {
        final dest = File('${tmp.path}/dl.mp4');
        await expectLater(
          client.download('${bad.baseUrl}/good.mp4', dest),
          throwsA(
            isA<WebDavException>().having(
              (e) => e.message,
              'message',
              allOf(contains('下载不完整'), contains('113206')),
            ),
          ),
        );
      } finally {
        client.close();
        await bad.close();
      }
    });

    test('正常下载：字节与源文件一致（对照组）', () async {
      final root = Directory('${tmp.path}/root2');
      Directory('${root.path}/lib').createSync(recursive: true);
      final src = File('test/fixtures/good.mp4');
      src.copySync('${root.path}/lib/good.mp4');

      final server = await TestDavServer.start(root);
      final client = WebDavClient(server.baseUrl);
      try {
        final dest = File('${tmp.path}/dl2.mp4');
        final bytes =
            await client.download('${server.baseUrl}/lib/good.mp4', dest);
        expect(bytes, src.lengthSync());
        expect(dest.readAsBytesSync(), src.readAsBytesSync());
      } finally {
        client.close();
        await server.close();
      }
    });

    test('PUT 大文件：进度回调单调递增且总数正确', () async {
      final root = Directory('${tmp.path}/root3');
      Directory('${root.path}/lib').createSync(recursive: true);
      final server = await TestDavServer.start(root);
      final client = WebDavClient(server.baseUrl);
      try {
        final payload = List<int>.generate(300000, (i) => i % 251);
        final file = File('${tmp.path}/up.bin')
          ..writeAsBytesSync(payload);
        final seen = <int>[];
        await client.upload(
          '${server.baseUrl}/lib/up.bin',
          file,
          onProgress: (done, total) {
            seen.add(done);
            expect(total, payload.length);
          },
        );
        expect(seen, isNotEmpty);
        expect(seen.last, payload.length);
        for (var i = 1; i < seen.length; i++) {
          expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
        }
        expect(
          File('${root.path}/lib/up.bin').readAsBytesSync().length,
          payload.length,
        );
      } finally {
        client.close();
        await server.close();
      }
    });
  });
}
