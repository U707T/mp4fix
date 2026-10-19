import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/app_controller.dart';
import 'package:mp4fix/src/app/app_scope.dart';
import 'package:mp4fix/src/app/home_shell.dart';
import 'package:mp4fix/src/app/models.dart';

/// SAF tree URI 展示名 + 「选完文件夹就白屏」的回归。
///
/// 事故：`_treeName()` 先取 `Uri.pathSegments`（已解码一次），又调了一次
/// `Uri.decodeComponent`。文件夹名含中文 / 空格 / `%` 时第二次解码抛
/// `Illegal percent encoding in URI`；而这个函数是在 `build()` 里被调用的，
/// 于是整页变成 ErrorWidget —— release 下没有红色报错屏，就是**一片白**。
/// 更糟的是坏 URI 已经写进 settings.json，重启后照样白屏，用户连设置都进不去。
void main() {
  group('treeUriDisplayName：只解码一次，永不抛', () {
    test('常见 SAF 路径取最后一级目录名', () {
      expect(
        treeUriDisplayName(
          'content://com.android.externalstorage.documents/tree/primary%3ADownload',
        ),
        'Download',
      );
      expect(
        treeUriDisplayName(
          'content://com.android.externalstorage.documents/tree/primary%3AMovies',
        ),
        'Movies',
      );
    });

    test('中文文件夹名（原白屏的直接触发点）', () {
      expect(
        treeUriDisplayName(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3A%E7%9B%B8%E6%9C%BA',
        ),
        '相机',
      );
      expect(
        treeUriDisplayName(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3ADCIM%2F%E7%9B%B8%E6%9C%BA',
        ),
        '相机',
        reason: '多级路径只显示最后一级',
      );
    });

    test('名字里带空格 / 百分号也不能炸', () {
      expect(
        treeUriDisplayName(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3AMovies%2Fa%20b',
        ),
        'a b',
      );
      expect(
        treeUriDisplayName(
          'content://com.android.externalstorage.documents/tree/'
          'primary%3ADownload%2F100%25Videos',
        ),
        '100%Videos',
      );
      // 非法百分号（用户文件夹真叫 "%zz"）→ 按原文返回，绝不抛
      expect(treeUriDisplayName('content://x/tree/%zz'), '%zz');
    });

    test('卷根目录 / 残缺 URI / 非 URI 都有兜底', () {
      expect(
        treeUriDisplayName(
          'content://com.android.externalstorage.documents/tree/primary%3A',
        ),
        'primary',
        reason: '卷根目录没有子目录名，退回卷名',
      );
      expect(
        treeUriDisplayName(
          'content://com.android.externalstorage.documents/tree/home%3A',
        ),
        'home',
      );
      // 拿不到目录名时原样返回，至少不会抛
      expect(treeUriDisplayName('content://x/tree/'), 'content://x/tree/');
      expect(treeUriDisplayName('content://x'), 'content://x');
      expect(treeUriDisplayName(''), '');
      expect(treeUriDisplayName('not a uri'), 'not a uri');
    });
  });

  group('回归：选了中文名文件夹后主界面必须还能渲染', () {
    // 注意：widget 测试跑在桌面宿主上，`AndroidPlatform.isSupported` 为 false，
    // 因此 build() 里走的是桌面分支、不会碰到 tree URI。真正的回归防线是上面
    // 那组纯函数用例（旧实现在这些输入上必抛）。这里只保证页面本身没被改坏。
    testWidgets('主界面 / 文件夹页可正常渲染', (tester) async {
      final controller = AppController();
      controller.settings.scanInputTreeUri =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3ADCIM%2F%E7%9B%B8%E6%9C%BA';

      await tester.pumpWidget(
        AppScope(
          controller: controller,
          child: const MaterialApp(home: HomeShell()),
        ),
      );
      await tester.tap(find.text('文件夹'));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'build() 里抛异常 → ErrorWidget → release 白屏',
      );
      expect(find.text('文件夹批量'), findsWidgets, reason: '页面没有被 ErrorWidget 顶掉');
    });

    testWidgets('输出文件夹同样是中文名时也不能白屏', (tester) async {
      final controller = AppController();
      controller.settings.outputTreeUri =
          'content://com.android.externalstorage.documents/tree/'
          'primary%3A%E8%A7%86%E9%A2%91%2F%E4%BF%AE%E5%A4%8D%E5%90%8E';

      await tester.pumpWidget(
        AppScope(
          controller: controller,
          child: const MaterialApp(home: HomeShell()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
