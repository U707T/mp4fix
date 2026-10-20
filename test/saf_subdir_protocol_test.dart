import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/platform/android_platform.dart';

/// SAF 落位的**协议层**回归：子目录与取消。
///
/// 1. `relativeDir` 必须原样传给平台侧 —— 递归扫描时产物要落回原子目录，
///    否则子目录里的同名文件会在根目录互相覆盖（这是数据丢失级的问题）。
/// 2. 平台侧取消时抛的是 `cancelled` 错误码，必须映射成
///    `SafWriteCancelledException`（界面显示「已取消」，而不是红色的「失败」）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mp4fix/platform');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  void mock(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  test('writeToTree 透传 relativeDir', () async {
    mock((call) async {
      expect(call.method, 'writeToTree');
      final args = call.arguments as Map;
      expect(args['treeUri'], 'content://tree/root');
      expect(args['name'], 'a.mp4');
      expect(args['sourcePath'], '/cache/a.mp4');
      expect(
        args['relativeDir'],
        'sub/dir',
        reason: '丢了 relativeDir → 产物落到根目录，覆盖同名的别的文件',
      );
      return 'content://tree/root/document/x';
    });

    final uri = await AndroidPlatform.writeToTree(
      treeUri: 'content://tree/root',
      name: 'a.mp4',
      sourcePath: '/cache/a.mp4',
      relativeDir: 'sub/dir',
    );
    expect(uri, 'content://tree/root/document/x');
  });

  test('根目录时不传 relativeDir（保持旧协议不变）', () async {
    mock((call) async {
      final args = call.arguments as Map;
      expect(args.containsKey('relativeDir'), isFalse);
      return 'content://x';
    });
    await AndroidPlatform.writeToTree(
      treeUri: 'content://t',
      name: 'a.mp4',
      sourcePath: '/c/a.mp4',
    );
  });

  test('平台侧取消 → SafWriteCancelledException（不是失败）', () async {
    mock((call) async {
      throw PlatformException(code: 'cancelled', message: '已取消（原文件未改动）');
    });

    await expectLater(
      AndroidPlatform.writeToTree(
        treeUri: 'content://t',
        name: 'a.mp4',
        sourcePath: '/c/a.mp4',
      ),
      throwsA(isA<SafWriteCancelledException>()),
    );
  });

  test('其它平台错误照旧冒泡（不能被当成取消）', () async {
    mock((call) async {
      throw PlatformException(code: 'platform_error', message: '磁盘已满');
    });

    await expectLater(
      AndroidPlatform.writeToTree(
        treeUri: 'content://t',
        name: 'a.mp4',
        sourcePath: '/c/a.mp4',
      ),
      throwsA(isA<PlatformException>()),
    );
  });

  test('existsInTree 用相对路径查询产物', () async {
    mock((call) async {
      expect(call.method, 'existsInTree');
      expect((call.arguments as Map)['name'], 'sub/a.mp4');
      return true;
    });
    expect(
      await AndroidPlatform.existsInTree('content://t', 'sub/a.mp4'),
      isTrue,
    );
  });

  test('saveToDownloads 透传 relativeDir', () async {
    mock((call) async {
      expect(call.method, 'saveToDownloads');
      expect((call.arguments as Map)['relativeDir'], 'sub');
      return '下载/MP4Fix/sub/a.mp4';
    });
    final where = await AndroidPlatform.saveToDownloads(
      name: 'a.mp4',
      sourcePath: '/c/a.mp4',
      relativeDir: 'sub',
    );
    expect(where, contains('sub/a.mp4'));
  });
}
