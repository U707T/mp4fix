import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/pages/settings_page.dart';

/// 「关于」里显示的版本号必须和 pubspec 一致。
///
/// 版本号写死在 `SettingsPage.appVersion` 里，发版时极易忘记同步 ——
/// 用户反馈问题时报的版本号对不上，排查就白费了。
void main() {
  test('设置页版本号 == pubspec version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)',
            multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml 里必须有 version');
    expect(
      SettingsPage.appVersion,
      match!.group(1),
      reason: '改了 pubspec 的版本号，记得同步 SettingsPage.appVersion',
    );
  });
}
