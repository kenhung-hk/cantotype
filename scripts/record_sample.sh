#!/bin/zsh
# 用 ffmpeg 錄一段 16k 單聲道 WAV 作測試（預設 8 秒），方便用 CLI 比較模型。
# 用法：scripts/record_sample.sh ~/Desktop/sample.wav [秒數]
set -e
OUT=${1:-sample.wav}
SECS=${2:-8}
echo "開始錄音 ${SECS} 秒…（講廣東話）"
ffmpeg -y -loglevel error -f avfoundation -i ":default" -t "$SECS" -ar 16000 -ac 1 -sample_fmt s16 "$OUT"
echo "已儲存 $OUT"
