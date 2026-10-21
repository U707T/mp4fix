/// 采样表（stbl 子盒）的共用解析器。
///
/// 检测（[Mp4Inspect]）与修复（[Mp4Repair]）必须对同一份文件得出**完全相同**的
/// 样本表；以前两边各写一套，边界检查与错误文案稍有出入，就成了两套独立解释。
/// 这里只保留一份：越界、巨大计数、表结构异常都在这里判掉。
library;

import 'dart:typed_data';

import 'binary.dart';
import 'boxes.dart';

/// 解析 stsc（sample-to-chunk）：`[firstChunk, samplesPerChunk, descIndex]`。
List<List<int>> parseStsc(Uint8List raw) {
  if (raw.length < 16) throw RepairException('stsc 盒过小（疑似损坏）');
  final cnt = u32AsInt(raw, 12);
  if (cnt <= 0) throw RepairException('stsc 表为空');
  checkTableFits(raw, cnt, 12, 16, 'stsc');
  final out = List<List<int>>.generate(cnt, (_) => List<int>.filled(3, 0));
  var p = 16;
  for (var i = 0; i < cnt; i++) {
    out[i][0] = u32(raw, p);
    out[i][1] = u32(raw, p + 4);
    out[i][2] = u32(raw, p + 8);
    p += 12;
  }
  for (var i = 1; i < cnt; i++) {
    if (out[i][0] <= out[i - 1][0]) throw RepairException('stsc 表异常');
  }
  return out;
}

/// 解析 stco / co64（chunk 偏移）。
List<int> parseStco(Uint8List raw, {required bool is64}) {
  if (raw.length < 16) throw RepairException('stco 盒过小（疑似损坏）');
  final cnt = u32AsInt(raw, 12);
  checkTableFits(raw, cnt, is64 ? 8 : 4, 16, is64 ? 'co64' : 'stco');
  final out = List<int>.filled(cnt, 0);
  var p = 16;
  for (var i = 0; i < cnt; i++) {
    out[i] = is64 ? u64(raw, p) : u32(raw, p);
    p += is64 ? 8 : 4;
  }
  return out;
}

/// 解析 stsz（样本大小；uniform 形式展开成逐样本）。
List<int> parseStsz(Uint8List raw) {
  if (raw.length < 20) throw RepairException('stsz 盒过小（疑似损坏）');
  final uniform = u32(raw, 12);
  final cnt = u32AsInt(raw, 16);
  if (uniform == 0) checkTableFits(raw, cnt, 4, 20, 'stsz');
  final out = List<int>.filled(cnt, 0);
  if (uniform != 0) {
    out.fillRange(0, cnt, uniform);
  } else {
    var p = 20;
    for (var i = 0; i < cnt; i++) {
      out[i] = u32(raw, p);
      p += 4;
    }
  }
  return out;
}

/// 解析 stts（解码时长）：行程编码展开成 `counts × deltas`。
({List<int> counts, List<int> deltas}) parseStts(Uint8List raw) {
  if (raw.length < 16) throw RepairException('stts 盒过小（疑似损坏）');
  final cnt = u32AsInt(raw, 12);
  checkTableFits(raw, cnt, 8, 16, 'stts');
  final counts = List<int>.filled(cnt, 0);
  final deltas = List<int>.filled(cnt, 0);
  var p = 16;
  for (var i = 0; i < cnt; i++) {
    counts[i] = u32(raw, p);
    deltas[i] = u32(raw, p + 4);
    p += 8;
  }
  return (counts: counts, deltas: deltas);
}
