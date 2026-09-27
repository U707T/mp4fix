#!/usr/bin/env python3
"""生成额外测试夹具（覆盖目前没测到的代码路径）：

  moov_last.mp4 —— ftyp + mdat + moov（moov 后置，应判为「可优化」，修复后应 faststart）
  co64.mp4      —— 把 32 位的 stco 表换成 64 位的 co64 表（覆盖 co64 读取路径）

用法：python3 tool/make_extra_fixtures.py
"""

import os
import struct
import sys

FOURCC = ('ftyp', 'moov', 'mdat', 'trak', 'mdia', 'minf', 'stbl', 'stco', 'co64')


def read_boxes(data, start, end):
    """返回 [(type, start, header, size)]。"""
    out = []
    pos = start
    while pos + 8 <= end:
        size = struct.unpack('>I', data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8].decode('latin-1')
        header = 8
        if size == 1:
            size = struct.unpack('>Q', data[pos + 8:pos + 16])[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header or pos + size > end:
            break
        out.append((typ, pos, header, size))
        pos += size
    return out


def children(data, box):
    _, start, header, size = box
    return read_boxes(data, start + header, start + size)


def find_all(data, root, path):
    """按路径递归找盒子；path 形如 ['trak','mdia','minf','stbl','stco']，返回匹配列表。"""
    current = [root]
    for name in path:
        nxt = []
        for b in current:
            for c in children(data, b):
                if c[0] == name:
                    nxt.append(c)
        if not nxt:
            return []
        current = nxt
    return current


def rewrite_box(data, box, replacement_bytes=None, patch_fn=None):
    """递归重建盒子字节：可选替换自身内容 / 对最内层 stco 做原位补丁。"""
    typ, start, header, size = box
    if replacement_bytes is not None:
        return replacement_bytes
    body_start = start + header
    body_end = start + size

    parts = []
    pos = body_start
    for c in read_boxes(data, body_start, body_end):
        gap = data[pos:c[1]]
        if gap:
            parts.append(gap)
        parts.append(rewrite_box(data, c, patch_fn=patch_fn))
        pos = c[1] + c[3]
    tail = data[pos:body_end]
    if tail:
        parts.append(tail)
    body = b''.join(parts)

    if typ in FOURCC and header == 8:
        return struct.pack('>I', 8 + len(body)) + typ.encode('latin-1') + body
    # 大盒子（本来用 64 位头）：保持 64 位头
    return struct.pack('>I', 1) + typ.encode('latin-1') + struct.pack('>Q', 16 + len(body)) + body


def make_moov_last(src, dst):
    data = open(src, 'rb').read()
    top = read_boxes(data, 0, len(data))
    ftyp = next(b for b in top if b[0] == 'ftyp')
    moov = next(b for b in top if b[0] == 'moov')
    mdat = next(b for b in top if b[0] == 'mdat')

    old_mdat_payload = mdat[1] + mdat[2]
    ftyp_bytes = data[ftyp[1]:ftyp[1] + ftyp[3]]
    mdat_bytes = data[mdat[1]:mdat[1] + mdat[3]]

    # 新布局：ftyp + mdat + moov ⇒ mdat 载荷前移 moov 的大小
    new_mdat_payload = len(ftyp_bytes) + mdat[2]
    delta = new_mdat_payload - old_mdat_payload

    def patch(box):
        typ, start, header, size = box
        if typ != 'stco':
            return None
        payload = bytearray(data[start:start + size])
        count = struct.unpack('>I', payload[12:16])[0]
        for i in range(count):
            off = 16 + i * 4
            value = struct.unpack('>I', payload[off:off + 4])[0] + delta
            if not (0 <= value <= 0xFFFFFFFF):
                raise SystemExit('stco 溢出：{value}')
            payload[off:off + 4] = struct.pack('>I', value)
        return bytes(payload)

    moov_bytes = rewrite_box_with_patch(data, moov, patch)
    with open(dst, 'wb') as f:
        f.write(ftyp_bytes)
        f.write(mdat_bytes)
        f.write(moov_bytes)
    print(f'{dst}: ftyp + mdat({mdat[3]}) + moov({len(moov_bytes)})，偏移位移 {delta:+d}')


def rewrite_box_with_patch(data, box, patch_fn):
    """重建盒子；对 patch_fn 返回非 None 的盒子使用其返回值。"""
    typ, start, header, size = box
    patched = patch_fn(box)
    if patched is not None:
        return patched
    body_start = start + header
    body_end = start + size
    parts = []
    pos = body_start
    for c in read_boxes(data, body_start, body_end):
        gap = data[pos:c[1]]
        if gap:
            parts.append(gap)
        parts.append(rewrite_box_with_patch(data, c, patch_fn))
        pos = c[1] + c[3]
    tail = data[pos:body_end]
    if tail:
        parts.append(tail)
    body = b''.join(parts)
    if header == 16:
        return struct.pack('>I', 1) + typ.encode('latin-1') + struct.pack('>Q', 16 + len(body)) + body
    return struct.pack('>I', 8 + len(body)) + typ.encode('latin-1') + body


def make_co64(src, dst):
    data = open(src, 'rb').read()
    top = read_boxes(data, 0, len(data))
    ftyp = next(b for b in top if b[0] == 'ftyp')
    moov = next(b for b in top if b[0] == 'moov')
    mdat = next(b for b in top if b[0] == 'mdat')

    among = find_all(data, moov, ['trak', 'mdia', 'minf', 'stbl', 'stco'])
    if not among:
        raise SystemExit('未找到 stco')

    # 先把 stco 换成 co64（条目 +4 字节），算出 moov 的膨胀量
    growth = 0
    for b in among:
        count = struct.unpack('>I', data[b[1] + 12:b[1] + 16])[0]
        growth += 4 * count

    # 新布局 = ftyp + moov'(= moov + growth) + mdat；delta 必须由实际布局推导
    # （原文件 moov 与 mdat 之间可能还有 free 等盒子，会被丢弃）
    old_mdat_payload = mdat[1] + mdat[2]
    ftyp_bytes = data[ftyp[1]:ftyp[1] + ftyp[3]]
    new_mdat_payload = len(ftyp_bytes) + (moov[3] + growth) + 8
    delta = new_mdat_payload - old_mdat_payload

    def patch(box):
        typ, start, header, size = box
        if typ != 'stco':
            return None
        count = struct.unpack('>I', data[start + 12:start + 16])[0]
        payload = bytearray()
        payload += struct.pack('>I', 0)      # version/flags
        payload += struct.pack('>I', count)  # entry_count
        for i in range(count):
            off = start + 16 + i * 4
            value = struct.unpack('>I', data[off:off + 4])[0] + delta
            payload += struct.pack('>Q', value)
        return struct.pack('>I', 8 + len(payload)) + b'co64' + bytes(payload)

    moov_bytes = rewrite_box_with_patch(data, moov, patch)
    mdat_bytes = data[mdat[1]:mdat[1] + mdat[3]]
    with open(dst, 'wb') as f:
        f.write(ftyp_bytes)
        f.write(moov_bytes)
        f.write(mdat_bytes)
    print(f'{dst}: ftyp + moov({len(moov_bytes)}) + mdat，co64 表 {len(among)} 个，位移 {delta:+d}')


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    fixtures = os.path.join(root, 'test', 'fixtures')
    src = os.path.join(fixtures, 'good.mp4')
    if not os.path.exists(src):
        raise SystemExit(f'缺少基础夹具：{src}')
    make_moov_last(src, os.path.join(fixtures, 'moov_last.mp4'))
    make_co64(src, os.path.join(fixtures, 'co64.mp4'))


if __name__ == '__main__':
    sys.exit(main())
