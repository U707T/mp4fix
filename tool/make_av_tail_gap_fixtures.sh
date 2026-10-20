#!/usr/bin/env bash
# 生成「尾部时长差」夹具（v2.9.3 回归用）。
#
#   av_tail_gap.mp4        视频 3.00s / 音频 2.02s → 画面比音轨长 ~0.98s
#   av_tail_gap_audio.mp4  视频 2.00s / 音频 3.02s → 音轨比画面长 ~1.02s
#
# 两个文件的交错本身都很紧凑（最大字节距离 < 200B），只有"结尾对不齐"。
# 旧判定只看"每个视频样本到最近音频样本的时间差"，会把这个时长差算成
# 「时间错位 0.9 秒」→ 误判需重排；而重排对它们逐字节无效。
#
# 用法：bash tool/make_av_tail_gap_fixtures.sh（需要 ffmpeg）
set -euo pipefail
cd "$(dirname "$0")/../test/fixtures"

ffmpeg -y -v error \
  -f lavfi -i "testsrc2=size=64x64:rate=10:duration=3" \
  -f lavfi -i "sine=frequency=440:duration=2:sample_rate=44100" \
  -map 0:v -map 1:a -c:v libx264 -profile:v baseline -pix_fmt yuv420p -crf 35 \
  -c:a aac -b:a 32k -movflags +faststart \
  -metadata title="mp4fix fixture: A/V tail gap" av_tail_gap.mp4

ffmpeg -y -v error \
  -f lavfi -i "testsrc2=size=64x64:rate=10:duration=2" \
  -f lavfi -i "sine=frequency=660:duration=3:sample_rate=44100" \
  -map 0:v -map 1:a -c:v libx264 -profile:v baseline -pix_fmt yuv420p -crf 35 \
  -c:a aac -b:a 32k -movflags +faststart \
  -metadata title="mp4fix fixture: audio longer than video" av_tail_gap_audio.mp4

ffprobe -v error -show_entries stream=codec_type,duration -of default=nw=1 av_tail_gap.mp4
ffprobe -v error -show_entries stream=codec_type,duration -of default=nw=1 av_tail_gap_audio.mp4
