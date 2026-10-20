import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/app_controller.dart';
import 'package:mp4fix/src/app/models.dart';
import 'package:mp4fix/src/app/settings_store.dart';

/// 设置落盘的稳定性回归。
///
/// 事故：WebDAV 的主机 / 路径 / 用户名输入框是**逐字符**触发保存的，而
/// `SettingsStore.save` 直接 `writeAsString` —— 多个写操作会互相覆盖同一个文件。
/// 进程恰好在写一半时被杀（切后台被回收、闪退），就留下半截 JSON；下次启动
/// `load()` 解析失败返回 null → 所有设置静默回到默认值（包括 SAF 文件夹授权 URI），
/// 用户看到的是「设置自己丢了、文件夹又要重新选」。
///
/// 现在：先在内存里序列化快照、串行写、先写临时文件再原子改名。
///
/// 注：这里锁的是「并发 / 高频保存后文件仍然完整可读」，以及「切后台时
/// 去抖中的设置会被立刻补写」—— 进程在写一半被杀这种时序无法在单元测试里
/// 复现，那部分靠实现上的原子改名来保证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory support;

  setUpAll(() {
    support = Directory.systemTemp.createTempSync('mp4fix-settings');
  });

  tearDownAll(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getApplicationSupportPath':
          return support.path;
        default:
          return support.path;
      }
    });
    final f = File('${support.path}/settings.json');
    if (f.existsSync()) f.deleteSync();
    final tmp = File('${support.path}/settings.json.tmp');
    if (tmp.existsSync()) tmp.deleteSync();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('并发保存不互相覆盖，最终落盘的是最后一次', () async {
    final a = AppSettings(thresholdMb: 1, nameSuffix: '_a');
    final b = AppSettings(thresholdMb: 8, nameSuffix: '_b');

    // 故意不等待：模拟用户快速输入 / 连续改设置
    final fa = SettingsStore.save(a);
    final fb = SettingsStore.save(b);
    await Future.wait([fa, fb]);

    final loaded = await SettingsStore.load();
    expect(loaded, isNotNull, reason: '并发写不能把 JSON 写坏');
    expect(loaded!.thresholdMb, 8);
    expect(loaded.nameSuffix, '_b');

    // 不能留下临时文件
    expect(File('${support.path}/settings.json.tmp').existsSync(), isFalse);
    // 内容必须是完整 JSON（能被再次解析）
    final raw = File('${support.path}/settings.json').readAsStringSync();
    expect(raw.trimRight().endsWith('}'), isTrue, reason: raw);
  });

  test('高频保存（逐字符输入）后依然能读回', () async {
    for (var i = 0; i < 40; i++) {
      await SettingsStore.save(
        AppSettings(thresholdMb: 2, nameSuffix: '_s$i'),
      );
    }
    final loaded = await SettingsStore.load();
    expect(loaded, isNotNull);
    expect(loaded!.nameSuffix, '_s39');
  });

  test('去抖期间切后台：flushSettings 立刻落盘，不丢刚改的设置', () async {
    File('${support.path}/settings.json').writeAsStringSync(
      '{"thresholdMb": 4}',
    );
    final c = AppController();
    c.updateSettings((s) {
      s.thresholdMb = 8;
      s.nameSuffix = '_oops';
    });
    // 还没到去抖窗口（250ms）就切后台
    await c.flushSettings();

    final loaded = await SettingsStore.load();
    expect(loaded, isNotNull);
    expect(loaded!.thresholdMb, 8, reason: '切后台时没补写 → 用户刚改的设置丢了');
    expect(loaded.nameSuffix, '_oops');
  });

  test('文件损坏时退回默认值而不是崩溃', () async {
    File('${support.path}/settings.json').writeAsStringSync('{"thresholdMb": ');
    expect(await SettingsStore.load(), isNull);
  });
}
