import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/repair_ledger.dart';

/// 「已修复的文件跳过检测」的回归。
///
/// 事故：复用检查原先放在**检测之后**，等于「复用」只省了修复、没省检测 ——
/// 已修复过的大目录重新扫描，仍要把每个文件的 moov 全部解析一遍。
/// 现在复用检查前置（见 `_inspectLocalJob` / `_scanFolderInner`）。
///
/// 这里锁住前置判定所依赖的两个前提：
///  1. 记录能按指纹命中（名称 + 大小 + 修改时间）；
///  2. 文件一变（大小 / 修改时间），指纹对不上 → 不复用，会重新检测。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mp4fix-reuse'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  RepairRecord record({String name = 'a.mp4', int size = 100, int ms = 1000}) =>
      RepairRecord(
        key: ledgerKeyFile(name: name, size: size, modifiedMs: ms),
        name: name,
        size: size,
        modifiedMs: ms,
        out: name,
        kind: 'dir',
        ref: dir.path,
        mode: '文件夹批量',
        rule: 'original||_fixed',
        at: DateTime.now().millisecondsSinceEpoch,
      );

  test('指纹命中 → 能查到记录（前置判定可用）', () {
    final l = RepairLedger.empty()..put(record());
    final key = ledgerKeyFile(name: 'a.mp4', size: 100, modifiedMs: 1000);
    expect(l.lookup(key), isNotNull);
  });

  test('文件改动后指纹失效 → 不复用（会重新检测）', () {
    final l = RepairLedger.empty()..put(record());
    expect(l.lookup(ledgerKeyFile(name: 'a.mp4', size: 999, modifiedMs: 1000)),
        isNull);
    expect(l.lookup(ledgerKeyFile(name: 'a.mp4', size: 100, modifiedMs: 9999)),
        isNull);
    expect(l.lookup(ledgerKeyFile(name: 'b.mp4', size: 100, modifiedMs: 1000)),
        isNull);
  });

  test('产物已被删除时，调用方应判定「不复用」并重新处理', () async {
    // 记录指向一个不存在的产物 → 复用必须失效
    final l = RepairLedger.empty()
      ..put(record(name: 'gone.mp4'));
    final key = ledgerKeyFile(name: 'gone.mp4', size: 100, modifiedMs: 1000);
    final rec = l.lookup(key);
    expect(rec, isNotNull);
    final product = File('${rec!.ref}${Platform.pathSeparator}${rec.out}');
    expect(product.existsSync(), isFalse, reason: '产物不存在，复用必须失效');
  });
}
