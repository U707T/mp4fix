import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/models.dart';

/// 输出命名规则（设置 → 文件命名）与设置序列化。
void main() {
  group('applyNameRule', () {
    test('原名：不做任何改动', () {
      expect(
        applyNameRule('a.m4v', mode: OutputNameMode.original),
        'a.m4v',
      );
    });

    test('后缀：插在扩展名之前，扩展名保留', () {
      expect(
        applyNameRule('a.m4v', mode: OutputNameMode.suffix, suffix: '_fixed'),
        'a_fixed.m4v',
      );
      expect(
        applyNameRule('电影 01.MP4',
            mode: OutputNameMode.suffix, suffix: '_修复'),
        '电影 01_修复.MP4',
      );
    });

    test('前缀 / 前后缀', () {
      expect(
        applyNameRule('a.mp4', mode: OutputNameMode.prefix, prefix: 'new_'),
        'new_a.mp4',
      );
      expect(
        applyNameRule('a.mp4',
            mode: OutputNameMode.both, prefix: 'new_', suffix: '_fixed'),
        'new_a_fixed.mp4',
      );
    });

    test('没有扩展名也能工作', () {
      expect(
        applyNameRule('novideo', mode: OutputNameMode.suffix, suffix: '_x'),
        'novideo_x',
      );
    });

    test('非法字符会被清掉（Windows 文件名约束）', () {
      expect(
        applyNameRule('a.mp4',
            mode: OutputNameMode.suffix, suffix: r'_fi/x\e*d?'),
        'a_fixed.mp4',
      );
      expect(
        applyNameRule('a.mp4', mode: OutputNameMode.prefix, prefix: '  new_  '),
        'new_a.mp4',
      );
    });

    test('前缀 / 后缀为空时退回原名（不生成同名文件）', () {
      expect(
        applyNameRule('a.mp4', mode: OutputNameMode.prefix, prefix: '  '),
        'a.mp4',
      );
      expect(
        applyNameRule('a.mp4', mode: OutputNameMode.suffix, suffix: ''),
        'a.mp4',
      );
      expect(
        applyNameRule('a.mp4', mode: OutputNameMode.both),
        'a.mp4',
      );
    });

    test('sanitizeNamePart：去掉路径分隔符与首尾点 / 空格', () {
      expect(sanitizeNamePart(r'..a/b\c..'), 'abc');
      expect(sanitizeNamePart('  x  '), 'x');
    });
  });

  group('AppSettings', () {
    test('命名规则 / 复用开关能往返 JSON', () {
      final settings = AppSettings(
        nameMode: OutputNameMode.both,
        namePrefix: '修_',
        nameSuffix: '_好',
        reuseRepairs: false,
      );
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.nameMode, OutputNameMode.both);
      expect(restored.namePrefix, '修_');
      expect(restored.nameSuffix, '_好');
      expect(restored.reuseRepairs, isFalse);
      expect(restored.nameRuleId, settings.nameRuleId);
    });

    test('老版本设置（没有新字段）用默认值', () {
      final restored = AppSettings.fromJson(const {
        'thresholdMb': 2,
      });
      expect(restored.thresholdMb, 2);
      expect(restored.nameMode, OutputNameMode.original);
      expect(restored.nameSuffix, '_fixed');
      expect(restored.reuseRepairs, isTrue);
    });

    test('规则指纹随设置变化（记录据此失效）', () {
      final a = AppSettings();
      final b = AppSettings(
        nameMode: OutputNameMode.suffix,
        nameSuffix: '_done',
      );
      expect(a.nameRuleId == b.nameRuleId, isFalse);
      expect(a.applyOutputName('x.mp4'), 'x.mp4');
      expect(b.applyOutputName('x.mp4'), 'x_done.mp4');
    });
  });
}
