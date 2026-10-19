import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/models.dart';

/// 「就地覆盖必须命中原文件」的回归 —— 输出名必须**保留原扩展名**。
///
/// 事故：`_outputName()` 曾把扩展名硬编码成 `.mp4`。于是 `.mov` / `.m4v` 修复后
/// 产物叫 `同名.mp4`，而文件夹页默认「就地覆盖输入文件夹」——
/// 结果**原 `.mov` 没被替换，文件夹里反而多出一个 `.mp4`**。
/// 用户看到的现象是「修完了，但原文件还是卡的，还多了一堆文件」。
void main() {
  group('输出名保留原扩展名', () {
    test('默认（原名）模式：输出名与输入名完全一致', () {
      final s = AppSettings();
      for (final n in ['a.mp4', 'b.mov', 'c.m4v', 'd.MP4', '带空格 的名字.mov']) {
        expect(s.applyOutputName(n), n, reason: '就地覆盖必须命中同名文件：$n');
      }
    });

    test('加后缀模式：保留原扩展名，不是强制 .mp4', () {
      final s = AppSettings(nameMode: OutputNameMode.suffix, nameSuffix: '_fixed');
      expect(s.applyOutputName('a.mov'), 'a_fixed.mov');
      expect(s.applyOutputName('b.m4v'), 'b_fixed.m4v');
      expect(s.applyOutputName('c.mp4'), 'c_fixed.mp4');
    });

    test('加前缀模式：保留原扩展名', () {
      final s = AppSettings(nameMode: OutputNameMode.prefix, namePrefix: '修复_');
      expect(s.applyOutputName('x.mov'), '修复_x.mov');
    });

    test('无扩展名：不凭空造一个 .mp4', () {
      final s = AppSettings();
      expect(s.applyOutputName('noext'), 'noext');
    });

    test('多点文件名：只按最后一个点拆扩展名', () {
      final s = AppSettings(nameMode: OutputNameMode.suffix, nameSuffix: '_f');
      expect(s.applyOutputName('a.b.c.mov'), 'a.b.c_f.mov');
    });
  });

  group('就地覆盖的判定依据', () {
    test('同名即覆盖：输出名 == 输入名时，落位会替换原文件', () {
      final s = AppSettings();
      const input = '影片.mov';
      final output = s.applyOutputName(input);
      expect(output, input, reason: '名字一致 → 落位时 target 就是原文件 → 覆盖生效');
    });
  });
}
