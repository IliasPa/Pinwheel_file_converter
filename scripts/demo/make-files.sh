#!/bin/bash
# Makes the sample files for recording Pinwheel's 30-second video (see
# scripts/demo/RECORDING.md): three photos, a video, a podcast intro, a PDF
# with tables, a Word document, a spreadsheet and a zip.
# Usage: scripts/demo/make-files.sh [folder]   (default: ~/Desktop/Pinwheel Demo)
# Run it again before each take: it puts the folder back as it was.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

OUT="${1:-$HOME/Desktop/Pinwheel Demo}"
MARK="$OUT/.pinwheel-demo"   # only a folder with this in it is ever replaced

command -v ffmpeg >/dev/null || { echo "error: needs ffmpeg (brew install ffmpeg)" >&2; exit 1; }
if [ -e "$OUT" ]; then
    if [ -f "$MARK" ]; then
        rm -rf "$OUT"
    else
        echo "error: \"$OUT\" is already there and wasn't made by this script; choose another folder" >&2
        exit 1
    fi
fi
mkdir -p "$OUT"
touch "$MARK"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ff() { ffmpeg -hide_banner -loglevel error -nostdin -y "$@"; }

echo "==> Drawing the photos, the PDF, the spreadsheet and the Word document"
# (grep finding nothing to show is fine; swiftc failing still stops here.)
swiftc -O "$ROOT/scripts/demo/make-files.swift" -o "$WORK/make-files" 2>&1 | (filter_toolchain_noise || true)
"$WORK/make-files" "$ROOT/docs/index.html" "$OUT" "$WORK"

echo "==> IMG_4107.MOV (15 seconds, HEVC like an iPhone's, about 75 MB)"
# A slow pan across the boat picture, with grain, and the sound of the sea
# (brown noise rising and falling like waves).
ff -loop 1 -framerate 30 -i "$WORK/boat.png" \
   -f lavfi -i "anoisesrc=color=brown:amplitude=0.5:duration=15:sample_rate=48000" \
   -filter_complex "[0:v]crop=1920:1080:'min(t*32,480)':135,noise=alls=8:allf=t,format=yuv420p[v];[1:a]lowpass=f=600,volume='0.35+0.25*sin(2*PI*t/5)':eval=frame,afade=t=in:d=1,afade=t=out:st=14:d=1,aformat=channel_layouts=stereo[a]" \
   -map "[v]" -map "[a]" -t 15 -c:v hevc_videotoolbox -b:v 40M -tag:v hvc1 -c:a aac -b:a 192k \
   -metadata creation_time="2026-06-16T10:24:00Z" "$OUT/IMG_4107.MOV"

echo "==> Podcast intro.wav (a voice over a soft chord)"
TEXT="Hello, and welcome to Island Notes, the podcast about small trips to small places. \
This week: three days on Santorini. We'll walk the ten kilometres from Fira to Oia along the edge of the caldera, \
find the old lighthouse at Akrotiri, and take a boat to the hot springs in the middle of the bay. \
And of course, we'll talk about the sunsets. Grab a coffee, and let's go."
say -v Samantha -o "$WORK/voice.aiff" "$TEXT" 2>/dev/null || say -o "$WORK/voice.aiff" "$TEXT"
VOICE=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/voice.aiff")
LENGTH=$(echo "$VOICE + 5" | bc)
ff -i "$WORK/voice.aiff" \
   -f lavfi -i "aevalsrc='0.05*sin(2*PI*220*t)*(0.7+0.3*sin(2*PI*0.2*t))+0.035*sin(2*PI*277.18*t)+0.035*sin(2*PI*329.63*t)+0.02*sin(2*PI*110*t)':s=44100:d=$LENGTH" \
   -filter_complex "[0:a]aresample=44100,aformat=channel_layouts=stereo,adelay=2500|2500,apad=whole_dur=$LENGTH[v];[1:a]aformat=channel_layouts=stereo,afade=t=in:d=2[m];[v][m]amix=inputs=2:duration=first:normalize=0,afade=t=out:st=$(echo "$LENGTH - 2" | bc):d=2,aformat=sample_fmts=s16[a]" \
   -map "[a]" -c:a pcm_s16le "$OUT/Podcast intro.wav"

echo "==> Photos.zip"
(cd "$OUT" && zip -q -X "Photos.zip" IMG_4021.HEIC IMG_4022.HEIC IMG_4023.HEIC)

echo "==> $(find "$OUT" -type f ! -name '.*' | wc -l | tr -d ' ') files in $OUT"
ls -lh "$OUT" | tail -n +2 | awk '{print "    " $5 "\t" substr($0, index($0, $9))}'
