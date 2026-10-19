import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/platform/android_platform.dart';

/// 「恢复 .mp4fix-bak 残留」的平台通道协议测试。
///
/// 事故链（v2.7.0 → v2.7.1）：
///  1. SAF 落位把原文件改名成 `xxx.mp4fix-bak`，正式名消失；
///  2. v2.7.1 加了恢复功能，但 `restoreBackup` 只在**根目录**找文件 ——
///     而残留几乎都在子目录里（用户实际是 `/baidu/flyflow/xxx.mp4fix-bak`），
///     于是「扫描能扫到、恢复却全部失败」。
///
/// 修复：扫描结果带上 `parentUri`，恢复时按该目录定位。
/// 这里锁住协议层：`parentUri` 必须被解析并原样传给恢复调用。
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

  group('listBackupLeftovers 解析', () {
    test('子目录里的残留：parentPath / parentUri 都要带回来', () async {
      mock((call) async {
        expect(call.method, 'listBackupLeftovers');
        expect((call.arguments as Map)['treeUri'], 'content://tree/root');
        return [
          {
            'backupName': '185体育.mp4.mp4fix-bak',
            'originalName': '185体育.mp4',
            'size': 1023218688,
            'parentPath': 'flyflow',
            'parentUri': 'content://tree/root/document/flyflow',
          },
          {
            'backupName': 'a.mp4.mp4fix-bak',
            'originalName': 'a.mp4',
            'size': 100,
            'parentPath': '',
            'parentUri': 'content://tree/root/document/root',
          },
        ];
      });

      final list =
          await AndroidPlatform.listBackupLeftovers('content://tree/root');

      expect(list, hasLength(2));
      expect(list[0].backupName, '185体育.mp4.mp4fix-bak');
      expect(list[0].originalName, '185体育.mp4');
      expect(list[0].size, 1023218688);
      expect(
        list[0].parentUri,
        'content://tree/root/document/flyflow',
        reason: '子目录 URI 必须保留 —— 否则恢复只在根目录找，必然失败',
      );
      expect(list[0].displayPath, 'flyflow/185体育.mp4');
      // 根目录的相对路径为空
      expect(list[1].displayPath, 'a.mp4');
    });

    test('缺字段 / 脏数据不崩，跳过无效项', () async {
      mock((call) async => [
            {'backupName': 'x.mp4.mp4fix-bak'}, // 缺 originalName
            {'originalName': 'y.mp4'}, // 缺 backupName
            {
              'backupName': 'ok.mp4.mp4fix-bak',
              'originalName': 'ok.mp4',
              'size': -1,
            },
          ]);
      final list = await AndroidPlatform.listBackupLeftovers('content://t');
      expect(list, hasLength(1));
      expect(list.single.originalName, 'ok.mp4');
      expect(list.single.size, -1);
      expect(list.single.parentPath, '');
    });

    test('平台异常时返回空列表（不打断界面）', () async {
      mock((call) async => throw PlatformException(code: 'boom'));
      expect(await AndroidPlatform.listBackupLeftovers('content://t'), isEmpty);
    });
  });

  group('restoreBackup 传参', () {
    test('parentUri 必须原样传给平台侧', () async {
      String? gotParent;
      mock((call) async {
        expect(call.method, 'restoreBackup');
        final args = call.arguments as Map;
        gotParent = args['parentUri'] as String?;
        expect(args['backupName'], 'a.mp4.mp4fix-bak');
        return true;
      });

      final ok = await AndroidPlatform.restoreBackup(
        treeUri: 'content://tree/root',
        backupName: 'a.mp4.mp4fix-bak',
        parentUri: 'content://tree/root/document/sub',
      );

      expect(ok, isTrue);
      expect(
        gotParent,
        'content://tree/root/document/sub',
        reason: '子目录 URI 丢了 → 恢复只会在根目录找 → 全部失败',
      );
    });

    test('不给 parentUri 时传 null（平台侧退回根目录）', () async {
      Object? gotParent = 'sentinel';
      mock((call) async {
        gotParent = (call.arguments as Map)['parentUri'];
        return true;
      });
      await AndroidPlatform.restoreBackup(
        treeUri: 'content://t',
        backupName: 'b.mp4.mp4fix-bak',
      );
      expect(gotParent, isNull);
    });

    test('平台返回 false（正式名已存在，不覆盖）时如实返回', () async {
      mock((call) async => false);
      expect(
        await AndroidPlatform.restoreBackup(
          treeUri: 'content://t',
          backupName: 'c.mp4.mp4fix-bak',
          parentUri: 'content://t/d',
        ),
        isFalse,
      );
    });
  });
}
