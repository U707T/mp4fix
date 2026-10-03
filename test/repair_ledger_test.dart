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
    String out = 'a.mp4',
    String kind = 'dir',
    String ref = '/out',
    int at = 1,
    String rule = 'original||_fixed',
  }) => RepairRecord(
    key: key,
    name: 'a.mp4',
    size: 100,
    modifiedMs: 123,
    out: out,
    kind: kind,
    ref: ref,
    mode: '本地文件',
    rule: rule,
    at: at,
  );

  test('指纹：本地用 名称+大小+修改时间，远端用 URL+大小', () {
    expect(ledgerKeyFile(name: 'a.mp4', size: 7, modifiedMs: 9),
        'f|a.mp4|7|9');
    expect(ledgerKeyFile(name: 'a.mp4', size: 7, modifiedMs: 0), 'f|a.mp4|7|0');
    expect(ledgerKeyRemote(url: 'http://x/y.mp4', size: 7),
        'r|http://x/y.mp4|7');
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
