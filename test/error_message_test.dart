import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mp4fix/src/app/models.dart';

/// 错误文案回归：常见 IO 错误给可操作的中文提示，其余剥掉异常类型前缀。
void main() {
  test('IO 错误 → 可操作提示', () {
    expect(
      describeError(PathNotFoundException(
        "Cannot open file, path = '/a/b.mp4'",
        const OSError('No such file or directory', 2),
      )),
      contains('目标目录不存在'),
    );
    expect(
      describeError(
        const FileSystemException('failed', '/a/b.mp4', OSError('denied', 13)),
      ),
      contains('没有写入权限'),
    );
    expect(
      describeError(FileSystemException(
        'write failed',
        '/a',
        const OSError('No space left on device', 28),
      )),
      contains('存储空间不足'),
    );
  });

  test('其余异常 → 去掉类型前缀', () {
    expect(describeError(StateError('请先选择输入文件夹')), '请先选择输入文件夹');
    expect(describeError(Exception('读取失败')), '读取失败');
  });
}
