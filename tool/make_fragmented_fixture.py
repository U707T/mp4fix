#!/usr/bin/env python3
"""生成分片（fragmented）MP4 测试夹具。

  fragmented.mp4     —— ffmpeg 生成的分片 MP4（empty_moov，8 个 moof）。
                        先用下面的命令生成，再运行本脚本：
                        ffmpeg -y -f lavfi -i testsrc2=size=320x240:rate=30:duration=4 \\
                          -f lavfi -i sine=frequency=440:sample_rate=48000:duration=4 \\
                          -c:v libx264 -preset ultrafast -g 30 -pix_fmt yuv420p \\
                          -c:a aac -b:a 96k \\
                          -movflags frag_keyframe+empty_moov -frag_duration 500000 \\
                          -f mp4 test/fixtures/fragmented.mp4

  fragmented_hybrid.mp4 —— 由 ffmpeg 直接生成（moov 采样表非空 + 分片 的“混合”写法）：
                        ffmpeg -y -f lavfi -i testsrc2=size=320x240:rate=30:duration=4 \\
                          -f lavfi -i sine=frequency=440:sample_rate=48000:duration=4 \\
                          -c:v libx264 -preset ultrafast -g 30 -pix_fmt yuv420p \
                          -c:a aac -b:a 96k -movflags +frag_keyframe \\
                          -f mp4 test/fixtures/fragmented_hybrid.mp4

  fragmented_bad.mp4 —— 由 fragmented.mp4 重新打包的“交错极差”版本：
                        视频数据与音频数据分别集中在文件两端（同刻距离 ≈ 视频块大小），
                        并刻意覆盖多种分片写法（逐样本 duration+size+flags、
                        同一 traf 多个 trun、tfhd 默认 duration、
                        default-base-is-moof 等）。

用法：python3 tool/make_fragmented_fixture.py
"""

import os
import struct
import sys

VIDEO = 1
AUDIO = 2


def read_boxes(data, start, end):
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
    return read_boxes(data, box[1] + box[2], box[1] + box[3])


def read_fragments(data):
    """读回 fragmented.mp4 的全部样本：(sizes, durations, sync, bytes) 按轨道。"""
    top = read_boxes(data, 0, len(data))
    result = {VIDEO: ([], [], [], []), AUDIO: ([], [], [], [])}
    for typ, pos, header, size in top:
        if typ != 'moof':
            continue
        for traf in [b for b in children(data, (typ, pos, header, size))
                     if b[0] == 'traf']:
            track_id = None
            base = pos  # default-base-is-moof
            default_dur = None
            default_flags = 0
            tfdt = 0
            trun_list = []
            for ctyp, cp, ch, cs in children(data, traf):
                if ctyp == 'tfhd':
                    flags = struct.unpack('>I', data[cp + 8:cp + 12])[0] & 0xFFFFFF
                    q = cp + 12
                    track_id = struct.unpack('>I', data[q:q + 4])[0]
                    q += 4
                    if flags & 1:
                        base = struct.unpack('>Q', data[q:q + 8])[0]
                        q += 8
                    if flags & 2:
                        q += 4
                    if flags & 8:
                        default_dur = struct.unpack('>I', data[q:q + 4])[0]
                        q += 4
                    if flags & 16:
                        q += 4
                    if flags & 32:
                        default_flags = struct.unpack('>I', data[q:q + 4])[0]
                        q += 4
                elif ctyp == 'tfdt':
                    ver = data[cp + 8]
                    tfdt = struct.unpack('>Q' if ver == 1 else '>I',
                                         data[cp + 12:cp + 20 if ver == 1 else cp + 16])[0]
                elif ctyp == 'trun':
                    trun_list.append((cp, ch, cs))
            trun_list.sort()
            cursor = tfdt
            last_end = None
            for cp, ch, cs in trun_list:
                flags = struct.unpack('>I', data[cp + 8:cp + 12])[0] & 0xFFFFFF
                count = struct.unpack('>I', data[cp + 12:cp + 16])[0]
                q = cp + 16
                doff = None
                first_flags = None
                if flags & 1:
                    doff = struct.unpack('>i', data[q:q + 4])[0]
                    q += 4
                if flags & 4:
                    first_flags = struct.unpack('>I', data[q:q + 4])[0]
                    q += 4
                run_start = base + doff if doff is not None else (last_end or base)
                off = run_start
                for i in range(count):
                    dur = struct.unpack('>I', data[q:q + 4])[0] if flags & 0x100 else default_dur
                    q += 4 if flags & 0x100 else 0
                    sz = struct.unpack('>I', data[q:q + 4])[0] if flags & 0x200 else None
                    q += 4 if flags & 0x200 else 0
                    fl = struct.unpack('>I', data[q:q + 4])[0] if flags & 0x400 else (
                        first_flags if i == 0 and first_flags is not None else default_flags)
                    q += 4 if flags & 0x400 else 0
                    if flags & 0x800:
                        q += 4
                    sizes, durs, sync, chunks = result[track_id]
                    sizes.append(sz)
                    durs.append(dur)
                    sync.append((fl & 0x10000) == 0)
                    chunks.append(data[off:off + sz])
                    off += sz
                    cursor += dur
                last_end = off
    return result


def build_box(typ, payload):
    return struct.pack('>I', 8 + len(payload)) + typ.encode('latin-1') + payload


def build_trun(count, doff, entries):
    """entries: list of (dur, size, flags)；值为 None 的字段不写。

    flags 中的字段出现与否按所有条目统一决定（符合 trun 的语义）。
    doff=None 表示不写 data_offset（隐式接续上一 run / base）。
    """
    flags = 0
    if doff is not None:
        flags |= 0x1
    if any(e[0] is not None for e in entries):
        flags |= 0x100
    if any(e[1] is not None for e in entries):
        flags |= 0x200
    if any(e[2] is not None for e in entries):
        flags |= 0x400
    payload = struct.pack('>I', flags) + struct.pack('>I', count)
    if doff is not None:
        payload += struct.pack('>i', doff)
    for dur, sz, fl in entries:
        if dur is not None:
            payload += struct.pack('>I', dur)
        if sz is not None:
            payload += struct.pack('>I', sz)
        if fl is not None:
            payload += struct.pack('>I', fl)
    return build_box('trun', payload)


def build_moof(seq, trafs):
    mfhd = build_box('mfhd', struct.pack('>II', 0, seq))
    return build_box('moof', mfhd + b''.join(trafs))


def make_bad(src, dst):
    data = open(src, 'rb').read()
    top = read_boxes(data, 0, len(data))
    ftyp = next(b for b in top if b[0] == 'ftyp')
    moov = next(b for b in top if b[0] == 'moov')
    ftyp_bytes = data[ftyp[1]:ftyp[1] + ftyp[3]]
    moov_bytes = data[moov[1]:moov[1] + moov[3]]

    frag = read_fragments(data)
    v_sizes, v_durs, v_sync, v_bytes = frag[VIDEO]
    a_sizes, a_durs, a_sync, a_bytes = frag[AUDIO]
    v_total = sum(v_sizes)
    a_total = sum(a_sizes)
    assert len(v_sizes) > 100 and len(a_sizes) > 100

    KEY = 0x02000000
    DELTA = 0x01010000
    v_flags = [KEY if s else DELTA for s in v_sync]

    # 两遍计算：第一遍用占位 data_offset 求盒子大小（字段结构保持不变），
    # 第二遍填入真实偏移。
    def build_video_traf(doff1, doff2):
        half = 60
        trun1 = build_trun(half, doff1, [
            (v_durs[i], v_sizes[i], v_flags[i]) for i in range(half)])
        trun2 = build_trun(len(v_sizes) - half, doff2, [
            (v_durs[i], v_sizes[i], v_flags[i]) for i in range(half, len(v_sizes))])
        tfhd = build_box('tfhd', struct.pack('>II', 0x020020, VIDEO) +
                         struct.pack('>I', DELTA))  # default-base-is-moof + 默认 flags
        tfdt = build_box('tfdt', struct.pack('>II', 0, 0))  # version 0 + base 0
        return build_box('traf', tfhd + tfdt + trun1 + trun2)

    # 音频 traf：只写 size，duration 用 tfhd 默认值（常见写法）
    def build_audio_traf(doff):
        trun = build_trun(len(a_sizes), doff, [
            (None, a_sizes[i], None) for i in range(len(a_sizes))])
        tfhd = build_box('tfhd', struct.pack('>II', 0x020008, AUDIO) +
                         struct.pack('>I', a_durs[0]))
        tfdt = build_box('tfdt', struct.pack('>II', 0, 0))  # version 0 + base 0
        return build_box('traf', tfhd + tfdt + trun)

    m1_start = len(ftyp_bytes) + len(moov_bytes)
    m1 = build_moof(1, [build_video_traf(0, 0)])
    m2 = build_moof(2, [build_audio_traf(0)])
    v_start = m1_start + len(m1) + len(m2) + 8
    a_start = v_start + v_total
    m2_start = m1_start + len(m1)
    v_half_end = v_start + sum(v_sizes[:60])

    m1 = build_moof(1, [build_video_traf(v_start - m1_start, v_half_end - m1_start)])
    m2 = build_moof(2, [build_audio_traf(a_start - m2_start)])

    mdat = build_box('mdat', b''.join(v_bytes) + b''.join(a_bytes))
    out = ftyp_bytes + moov_bytes + m1 + m2 + mdat
    open(dst, 'wb').write(out)
    print(f'{dst}: {len(out)} 字节；视频 {len(v_sizes)} 样本 / {v_total} 字节，'
          f'音频 {len(a_sizes)} 样本 / {a_total} 字节；视频块与音频块分居文件两端')


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    fixtures = os.path.join(root, 'test', 'fixtures')
    src = os.path.join(fixtures, 'fragmented.mp4')
    if not os.path.exists(src):
        raise SystemExit(f'缺少 {src}（先用文件末尾注释里的 ffmpeg 命令生成）')
    make_bad(src, os.path.join(fixtures, 'fragmented_bad.mp4'))


if __name__ == '__main__':
    sys.exit(main())
