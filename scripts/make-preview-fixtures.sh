#!/bin/bash
# Synthetic local test assets. FFmpeg is a developer-only fixture generator, not an app dependency.
set -euo pipefail
task_output="${1:?Pass a new output directory}"
task_ffmpeg="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
test ! -e "$task_output"
mkdir -p "$task_output"
"$task_ffmpeg" -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=640x360:rate=24:duration=6' \
  -f lavfi -i 'sine=frequency=440:duration=6:sample_rate=48000' -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$task_output/sample.mp4"
"$task_ffmpeg" -hide_banner -loglevel error -f lavfi -i 'color=c=0x267c9e:s=480x480' -frames:v 1 "$task_output/cover.jpg"
"$task_ffmpeg" -hide_banner -loglevel error -f lavfi -i 'sine=frequency=220:duration=12:sample_rate=44100' \
  -i "$task_output/cover.jpg" -map 0:a -map 1:v -c:a libmp3lame -c:v copy -disposition:v attached_pic \
  -metadata title='Preview 日本語 中文' -metadata artist='ArchiveDesk Test Artist' -metadata album='Synthetic Test Album' \
  -id3v2_version 3 "$task_output/cover.mp3"
(cd "$task_output"; /usr/bin/zip -q PreviewDemo.zip sample.mp4 cover.jpg cover.mp3)
