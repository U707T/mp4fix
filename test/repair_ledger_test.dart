import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/repair_ledger.dart';

/// 修复记录（"跳过已修复的文件"）的持久化与指纹。
void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mp4fix-ledger');
    file = File('${dir.path}/repair_ledger.json');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  RepairRecord record({
    String key = 'f|a.mp4|100|123',
    String name = 'a.mp4',
    String out = 'a.mp4',
    String kind = 'dir',
    String ref = '/out',
    int at = 1,
    String rule = 'original||_fixed',
  }) => RepairRecord(
    key: key,
    name: name,
    size: 100,
    modifiedMs: 123,
    out: out,
    kind: kind,
    ref: ref,
    mode: '本地文件',
    rule: rule,
    at: at,
  );

  test('指纹：本地用 位置+名称+大小+修改时间，远端用 URL+大小', () {
    // 位置为空时是旧格式（仓库里没有位置信息的老记录也能对上）
    expect(ledgerKeyFile(name: 'a.mp4', size: 7, modifiedMs: 9),
        'f||a.mp4|7|9');
    expect(ledgerKeyFile(name: 'a.mp4', size: 7, modifiedMs: 0), 'f||a.mp4|7|0');
    expect(ledgerKeyRemote(url: 'http://x/y.mp4', size: 7),
        'r|http://x/y.mp4|7');
  });

  test('指纹带位置：同一部片复制到别的目录后不会被误判「已修复」', () {
    final a = ledgerKeyFile(
      name: 'x.mp4',
      size: 100,
      modifiedMs: 5,
      path: '/media/A/x.mp4',
    );
    final b = ledgerKeyFile(
      name: 'x.mp4',
      size: 100,
      modifiedMs: 5,
      path: '/media/B/x.mp4',
    );
    expect(
      a,
      isNot(b),
      reason: '只用 名称+大小+修改时间 时，复制出来的副本会命中原件的记录 → '
          '显示「已修复」但其实一次都没修',
    );
  });

  test('purgeName：按名字清掉记录（恢复 .mp4fix-bak 之后不再算「已修复」）', () {
    final ledger = RepairLedger.empty()
      ..put(record(key: 'k1', name: 'a.mp4'))
      ..put(record(key: 'k2', name: 'a.mp4'))
      ..put(record(key: 'k3', name: 'b.mp4'));
    expect(ledger.purgeName('a.mp4'), 2);
    expect(ledger.lookup('k1'), isNull);
    expect(ledger.lookup('k2'), isNull);
    expect(ledger.lookup('k3'), isNotNull);
    expect(ledger.purgeName('none.mp4'), 0);
  });

  test('存盘 → 重新载入：内容一致', () async {
    final ledger = await RepairLedger.load(file);
    expect(ledger.length, 0);
    ledger.put(record());
    await ledger.save();
    expect(file.existsSync(), isTrue);

    final reloaded = await RepairLedger.load(file);
    final hit = reloaded.lookup('f|a.mp4|100|123');
    expect(hit, isNotNull);
    expect(hit!.out, 'a.mp4');
    expect(hit.kind, 'dir');
    expect(hit.ref, '/out');
    expect(hit.rule, 'original||_fixed');
  });

  test('remove / clear', () async {
    final ledger = await RepairLedger.load(null);
    ledger.put(record());
    expect(ledger.remove('f|a.mp4|100|123'), isTrue);
    expect(ledger.remove('不存在'), isFalse);
    ledger.put(record());
    ledger.clear();
    expect(ledger.length, 0);
  });

  test('损坏的 JSON 不会抛错（当作空记录）', () async {
    file.writeAsStringSync('{ this is not json');
    final ledger = await RepairLedger.load(file);
    expect(ledger.length, 0);
  });

  test('超过上限时按时间淘汰最旧的记录', () async {
    final ledger = await RepairLedger.load(null);
    for (var i = 0; i < RepairLedger.maxEntries + 5; i++) {
      ledger.put(record(key: 'f|$i|1|1', at: i));
    }
    expect(ledger.length, RepairLedger.maxEntries);
    expect(ledger.lookup('f|0|1|1'), isNull, reason: '最旧的应被淘汰');
    expect(
      ledger.lookup('f|${RepairLedger.maxEntries + 4}|1|1'),
      isNotNull,
      reason: '最新的应保留',
    );
  });

  test('缺少关键字段的条目会被忽略', () async {
    file.writeAsStringSync(
      '{"version":1,"entries":[{"key":"","out":"x"},{"key":"k","out":"o"}]}',
    );
    final ledger = await RepairLedger.load(file);
    expect(ledger.length, 1);
    expect(ledger.lookup('k')!.out, 'o');
  });
}
