import 'dart:convert';
import 'dart:io';

/// 一条修复记录。
///
/// 记录的是「某个输入文件（按 名称 + 大小 + 修改时间 指纹识别）修好后，
/// 产物落在哪里」。下次扫描到同一个文件时可以直接复用结果（跳过复制 /
/// 检测 / 重排），也就是不再重复干活 —— 文件一旦被改动（大小或修改时间变
/// 了），指纹对不上，记录自动失效。
class RepairRecord {
  RepairRecord({
    required this.key,
    required this.name,
    required this.size,
    required this.modifiedMs,
    required this.out,
    required this.kind,
    required this.ref,
    required this.mode,
    required this.rule,
    required this.at,
  });

  /// 指纹（见 [ledgerKeyFile] / [ledgerKeyRemote]）。
  final String key;

  /// 记录时的文件名 / 远端 URL。
  final String name;
  final int size;
  final int modifiedMs;

  /// 产物文件名（WebDAV 上传副本为远端文件名）。
  final String out;

  /// 产物位置类型：`dir`（桌面目录）/ `saf`（Android 所选文件夹）/
  /// `downloads`（Android 公共下载/MP4Fix）/ `remote`（服务器副本）。
  final String kind;

  /// 位置引用：目录路径 / SAF tree URI（其余为空）。
  final String ref;

  /// 展示用的来源说明（本地文件 / 文件夹批量 / WebDAV 上传副本 …）。
  final String mode;

  /// 记录时的命名规则指纹（规则变了就不复用）。
  final String rule;

  /// 记录时间（epoch 毫秒）。
  final int at;

  Map<String, Object?> toJson() => {
    'key': key,
    'name': name,
    'size': size,
    'modifiedMs': modifiedMs,
    'out': out,
    'kind': kind,
    'ref': ref,
    'mode': mode,
    'rule': rule,
    'at': at,
  };

  static RepairRecord? fromJson(Map<Object?, Object?> json) {
    String str(String k) => json[k] as String? ?? '';
    int asInt(String k) {
      final v = json[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return 0;
    }

    final key = str('key');
    final out = str('out');
    if (key.isEmpty || out.isEmpty) return null;
    return RepairRecord(
      key: key,
      name: str('name'),
      size: asInt('size'),
      modifiedMs: asInt('modifiedMs'),
      out: out,
      kind: str('kind'),
      ref: str('ref'),
      mode: str('mode'),
      rule: str('rule'),
      at: asInt('at'),
    );
  }
}

/// 本地 / 文件夹文件的指纹：名称 + 大小 + 修改时间（毫秒；未知为 0）。
String ledgerKeyFile({
  required String name,
  required int size,
  required int modifiedMs,
}) => 'f|$name|$size|$modifiedMs';

/// WebDAV 远端文件的指纹：URL + 大小。
String ledgerKeyRemote({required String url, required int size}) =>
    'r|$url|$size';

/// 修复记录仓库（JSON 文件持久化，最多保留 [maxEntries] 条）。
class RepairLedger {
  RepairLedger._(this._file);

  /// 纯内存仓库（不落盘）。
  static RepairLedger empty() => RepairLedger._(null);

  final Map<String, RepairRecord> _entries = {};
  final File? _file;

  /// 上限：超出后按时间淘汰最旧的记录（防止文件无限膨胀）。
  static const int maxEntries = 2000;

  /// 从 [file] 载入（文件不存在 / 损坏时返回空仓库，不抛错）。
  static Future<RepairLedger> load(File? file) async {
    final ledger = RepairLedger._(file);
    if (file == null) return ledger;
    try {
      if (!file.existsSync()) return ledger;
      final raw = jsonDecode(await file.readAsString());
      final list = switch (raw) {
        {'entries': final List<Object?> entries} => entries,
        final List<Object?> entries => entries,
        _ => const <Object?>[],
      };
      for (final item in list) {
        if (item is! Map) continue;
        final record = RepairRecord.fromJson(item.cast<Object?, Object?>());
        if (record != null) ledger._entries[record.key] = record;
      }
    } catch (_) {
      // 损坏就当作空记录，别让应用起不来
    }
    return ledger;
  }

  int get length => _entries.length;

  RepairRecord? lookup(String key) => _entries[key];

  void put(RepairRecord record) {
    _entries[record.key] = record;
    if (_entries.length > maxEntries) _prune();
  }

  bool remove(String key) => _entries.remove(key) != null;

  void clear() => _entries.clear();

  /// 保留最近的 [maxEntries] 条。
  void _prune() {
    final sorted = _entries.values.toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    _entries
      ..clear()
      ..addEntries(sorted.take(maxEntries).map((r) => MapEntry(r.key, r)));
  }

  /// 落盘（先写临时文件再改名，避免写一半损坏）。
  Future<void> save() async {
    final file = _file;
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'version': 1,
          'entries': _entries.values.map((r) => r.toJson()).toList(),
        }),
      );
      if (file.existsSync()) file.deleteSync();
      tmp.renameSync(file.path);
    } catch (_) {
      // 存不下就算了：复用只是优化，不能影响主流程
    }
  }
}
