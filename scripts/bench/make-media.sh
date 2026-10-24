#!/bin/bash
# Makes the bench's hard video and audio files (and the archives and text
# files in odd encodings) with ffmpeg and macOS's own tools.
# Usage: scripts/bench/make-media.sh <folder>
set -euo pipefail

OUT="${1:?folder}"
V="$OUT/video" A="$OUT/audio" S="$OUT/subtitles" Z="$OUT/archives" D="$OUT/documents" T="$OUT/sheets"
mkdir -p "$V" "$A" "$S" "$Z" "$D" "$T"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ff() { ffmpeg -hide_banner -loglevel error -nostdin -y "$@"; }
# A moving test picture and a two-tone sound, `seconds` long.
pattern() { echo "testsrc2=s=$1:r=$2:d=$3"; }
tone() { echo "sine=f=$1:d=$2:sample_rate=${3:-48000}"; }

# A cover picture for the tagged audio files.
ff -f lavfi -i "testsrc2=s=600x600:d=1" -frames:v 1 "$WORK/cover.jpg"

# Subtitles that go inside the MKV.
cat > "$WORK/inside.srt" <<'EOF'
1
00:00:00,500 --> 00:00:02,000
Καλημέρα από το MKV

2
00:00:02,500 --> 00:00:03,800
<i>Second line</i>
EOF

# Chapters for the audiobook and the MKV.
cat > "$WORK/chapters.txt" <<'EOF'
;FFMETADATA1
title=Βιβλίο ήχου
artist=Pinwheel Bench
[CHAPTER]
TIMEBASE=1/1000
START=0
END=2000
title=Κεφάλαιο 1
[CHAPTER]
TIMEBASE=1/1000
START=2000
END=4000
title=Chapter 2
EOF

echo "==> Videos"
# The usual: 1080p H.264 with AAC, a Greek title.
ff -f lavfi -i "$(pattern 1920x1080 30 3)" -f lavfi -i "$(tone 440 3)" -ac 2 \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 192k \
   -metadata title="Δοκιμή βίντεο" -metadata artist="Pinwheel Bench" -metadata location="+37.9838+023.7275/" \
   -movflags +faststart "$V/standard 1080p.mp4"

# A phone video filmed upright: stored sideways, shown turned (HEVC, hvc1).
ff -f lavfi -i "$(pattern 1920x1080 30 3)" -f lavfi -i "$(tone 523 3)" -ac 2 \
   -c:v hevc_videotoolbox -b:v 6M -tag:v hvc1 -c:a aac -b:a 128k "$WORK/sideways.mov"
ff -display_rotation:v:0 -90 -i "$WORK/sideways.mov" -c copy -metadata location="+40.6401+022.9444/" "$V/iphone portrait.mov"

# HDR: 10-bit HEVC in HLG, 4K.
ff -f lavfi -i "$(pattern 3840x2160 30 2)" -f lavfi -i "$(tone 330 2)" -ac 2 \
   -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -tag:v hvc1 \
   -x265-params "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
   -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -c:a aac "$V/hdr hlg 4k.mov"

# ProRes 4444 with a see-through left half.
ff -f lavfi -i "$(pattern 640x360 25 2)" \
   -vf "format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lt(X,W/2),255,0)'" \
   -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le "$V/prores alpha.mov"

# Odd size and film speed (23.976), 4:4:4 H.264 in MKV.
ff -f lavfi -i "$(pattern 721x405 24000/1001 3)" -f lavfi -i "$(tone 220 3)" \
   -c:v libx264 -preset veryfast -pix_fmt yuv444p -c:a libopus -b:a 96k "$V/odd size 721x405.mkv"

# MKV: two sound tracks, subtitles inside, chapters, frames at uneven times.
ff -f lavfi -i "$(pattern 1280x720 24 4)" -f lavfi -i "$(tone 300 4)" -f lavfi -i "$(tone 600 4)" \
   -i "$WORK/inside.srt" -i "$WORK/chapters.txt" \
   -map 0:v -map 1:a -map 2:a -map 3:s -map_metadata 4 -map_chapters 4 \
   -vf "select='lt(mod(n\,5)\,3)'" -fps_mode passthrough \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a libopus -b:a 96k -c:s srt \
   -metadata:s:a:0 language=eng -metadata:s:a:1 language=gre -metadata:s:s:0 language=gre \
   "$V/two tracks subtitles vfr.mkv"

# WebM: VP9 with see-through parts, Opus.
ff -f lavfi -i "$(pattern 640x360 30 2)" -f lavfi -i "$(tone 880 2)" \
   -vf "format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lt(Y,H/2),255,60)'" \
   -c:v libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0 -b:v 1M -c:a libopus "$V/vp9 alpha.webm"

# Older kinds: AVI (Xvid, MP3), WMV, MPEG-2, FLV, 3GP, an AVCHD camcorder clip.
ff -f lavfi -i "$(pattern 640x480 25 3)" -f lavfi -i "$(tone 440 3 44100)" \
   -c:v mpeg4 -vtag xvid -q:v 4 -c:a libmp3lame -b:a 128k "$V/xvid.avi"
ff -f lavfi -i "$(pattern 640x480 25 3)" -f lavfi -i "$(tone 440 3 44100)" \
   -c:v wmv2 -b:v 1M -c:a wmav2 -b:a 128k "$V/windows.wmv"
ff -f lavfi -i "$(pattern 720x576 25 3)" -f lavfi -i "$(tone 440 3)" \
   -c:v mpeg2video -b:v 4M -c:a mp2 -b:a 192k "$V/dvd.mpg"
ff -f lavfi -i "$(pattern 640x360 25 3)" -f lavfi -i "$(tone 440 3 44100)" \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac "$V/flash.flv"
ff -f lavfi -i "$(pattern 352x288 15 3)" -f lavfi -i "$(tone 440 3 8000)" -ac 1 \
   -c:v mpeg4 -c:a aac -b:a 24k "$V/old phone.3gp"
ff -f lavfi -i "$(pattern 1920x1080 25 3)" -f lavfi -i "aevalsrc=sin(2*PI*200*t)|sin(2*PI*300*t)|sin(2*PI*400*t)|0.2*sin(2*PI*50*t)|sin(2*PI*500*t)|sin(2*PI*600*t):d=3:s=48000:c=5.1" \
   -vf "interlace" -c:v libx264 -preset veryfast -flags +ilme+ildct -x264opts tff=1 -pix_fmt yuv420p \
   -c:a ac3 -b:a 448k -f mpegts "$V/camcorder interlaced.mts"

# 5.1 sound in an MP4 (AAC), no picture rotation, 25 fps.
ff -f lavfi -i "$(pattern 1280x720 25 3)" -f lavfi -i "aevalsrc=sin(2*PI*200*t)|sin(2*PI*300*t)|sin(2*PI*400*t)|0.2*sin(2*PI*50*t)|sin(2*PI*500*t)|sin(2*PI*600*t):d=3:s=48000:c=5.1" \
   -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 384k "$V/surround 5.1.mp4"

# No sound; one single frame; a 4K 60 fps clip; AV1; HEVC tagged hev1
# (QuickTime won't play that tag); MP4 subtitles (mov_text).
ff -f lavfi -i "$(pattern 1280x720 30 3)" -c:v libx264 -preset veryfast -pix_fmt yuv420p "$V/no sound.mp4"
ff -f lavfi -i "$(pattern 1280x720 30 1)" -frames:v 1 -c:v libx264 -pix_fmt yuv420p "$V/one frame.mp4"
ff -f lavfi -i "$(pattern 3840x2160 60 2)" -f lavfi -i "$(tone 440 2)" \
   -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac "$V/4k 60fps.mp4"
ff -f lavfi -i "$(pattern 1280x720 30 2)" -f lavfi -i "$(tone 440 2)" \
   -c:v libsvtav1 -preset 10 -pix_fmt yuv420p -c:a aac "$V/av1.mp4"
ff -f lavfi -i "$(pattern 1280x720 30 2)" -f lavfi -i "$(tone 440 2)" \
   -c:v libx265 -preset ultrafast -x265-params log-level=error -tag:v hev1 -pix_fmt yuv420p -c:a aac "$V/hevc hev1.mp4"
ff -f lavfi -i "$(pattern 1280x720 30 4)" -f lavfi -i "$(tone 440 4)" -i "$WORK/inside.srt" \
   -map 0 -map 1 -map 2 -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -c:s mov_text "$V/with subtitles.mp4"

# A minute of 1080p, for speed. A Greek name with an emoji.
ff -f lavfi -i "$(pattern 1920x1080 30 60)" -f lavfi -i "$(tone 440 60)" -ac 2 \
   -c:v h264_videotoolbox -b:v 8M -c:a aac "$V/one minute 1080p.mov"
ff -f lavfi -i "$(pattern 1280x720 30 2)" -f lavfi -i "$(tone 440 2)" \
   -c:v prores_ks -profile:v 0 -c:a pcm_s16le "$V/Διακοπές στη Σαντορίνη 🌅.mov"

# Only sound, in a video's container; and two damaged ones.
ff -f lavfi -i "$(tone 440 3)" -c:a aac "$V/sound only.mp4"
ff -f lavfi -i "$(pattern 1280x720 30 3)" -f lavfi -i "$(tone 440 3)" -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac "$WORK/whole.mp4"
head -c $(( $(stat -f%z "$WORK/whole.mp4") * 6 / 10 )) "$WORK/whole.mp4" > "$V/damaged cut short.mp4"
head -c 2000 /dev/urandom > "$V/not a video.mp4"

echo "==> Audio"
# MP3 with tags in Greek and a cover; mono VBR; silence; a damaged one.
ff -f lavfi -i "$(tone 440 4 44100)" -i "$WORK/cover.jpg" -map 0 -map 1 -ac 2 \
   -c:a libmp3lame -b:a 320k -c:v mjpeg -disposition:v attached_pic -id3v2_version 3 \
   -metadata title="Καλημέρα κόσμε" -metadata artist="Η Μπάντα" -metadata album="Δίσκος" -metadata date=2024 -metadata track=3 \
   "$A/Ελληνικό τραγούδι.mp3"
ff -f lavfi -i "$(tone 300 4 22050)" -ac 1 -c:a libmp3lame -q:a 6 "$A/mono vbr 22kHz.mp3"
ff -f lavfi -i "anullsrc=r=44100:cl=stereo:d=3" -c:a libmp3lame -b:a 128k "$A/silence.mp3"
ff -f lavfi -i "$(tone 440 4 44100)" -c:a flac "$WORK/whole.flac"
head -c $(( $(stat -f%z "$WORK/whole.flac") / 2 )) "$WORK/whole.flac" > "$A/cut short.flac"

# WAV in every depth; AIFF; Apple's CAF.
ff -f lavfi -i "$(tone 440 3 96000)" -ac 2 -c:a pcm_s24le "$A/hi-res 24bit 96kHz.wav"
ff -f lavfi -i "$(tone 440 3)" -ac 2 -c:a pcm_f32le "$A/float 32bit.wav"
ff -f lavfi -i "$(tone 440 3 8000)" -ac 1 -c:a pcm_u8 "$A/8bit 8kHz phone.wav"
ff -f lavfi -i "$(tone 440 0.1 44100)" -c:a pcm_s16le "$A/tiny 0.1s.wav"
ff -f lavfi -i "aevalsrc='if(lt(mod(t*220,1),0.5),0.999,-0.999)':d=3:s=44100" -ac 2 -c:a pcm_s16le "$A/too loud clipping.wav"
ff -f lavfi -i "$(tone 440 3 44100)" -ac 2 -c:a pcm_s16be "$A/aiff 16bit.aiff"
ff -f lavfi -i "$(tone 440 3)" -ac 2 -c:a pcm_s24le -f caf "$A/apple.caf"

# Lossless and many channels: 5.1 FLAC 24-bit with tags and a cover; ALAC.
ff -f lavfi -i "aevalsrc=sin(2*PI*200*t)|sin(2*PI*300*t)|sin(2*PI*400*t)|0.2*sin(2*PI*50*t)|sin(2*PI*500*t)|sin(2*PI*600*t):d=3:s=48000:c=5.1" \
   -i "$WORK/cover.jpg" -map 0 -map 1 -c:a flac -sample_fmt s32 -c:v copy -disposition:v attached_pic \
   -metadata title="Περιβάλλων ήχος" -metadata artist="Pinwheel Bench" "$A/surround 5.1 24bit.flac"
ff -f lavfi -i "$(tone 440 4 44100)" -i "$WORK/cover.jpg" -map 0 -map 1 -ac 2 -c:a alac -c:v copy -disposition:v attached_pic \
   -metadata title="Χωρίς απώλειες" -metadata artist="Pinwheel Bench" "$A/apple lossless.m4a"

# Others: Ogg Vorbis, Opus voice, WMA, HE-AAC, an audiobook with chapters,
# raw AAC (ADTS) and AC-3, and ten minutes of AAC for speed.
ff -f lavfi -i "$(tone 440 3 44100)" -ac 2 -c:a vorbis -strict -2 -metadata title="Ogg Ελληνικά" -metadata artist="Bench" "$A/vorbis.ogg"
ff -f lavfi -i "$(tone 300 3)" -ac 1 -c:a libopus -b:a 32k -metadata title="Φωνή" "$A/voice.opus"
ff -f lavfi -i "$(tone 440 3 44100)" -ac 2 -c:a wmav2 -b:a 128k -metadata title="Windows Ήχος" "$A/windows.wma"
ff -f lavfi -i "$(tone 440 3 44100)" -ac 2 -c:a aac_at -profile:a 4 -b:a 48k "$A/he-aac.m4a"
ff -f lavfi -i "$(tone 440 4 44100)" -i "$WORK/chapters.txt" -map 0 -map_metadata 1 -map_chapters 1 -c:a aac -b:a 64k -f ipod "$A/audiobook chapters.m4b"
ff -f lavfi -i "$(tone 440 3 44100)" -ac 2 -c:a aac -b:a 128k -f adts "$A/raw.aac"
ff -f lavfi -i "aevalsrc=sin(2*PI*200*t)|sin(2*PI*300*t)|sin(2*PI*400*t)|0.2*sin(2*PI*50*t)|sin(2*PI*500*t)|sin(2*PI*600*t):d=3:s=48000:c=5.1" -c:a ac3 -b:a 448k "$A/movie sound.ac3"
ff -f lavfi -i "$(tone 440 600 44100)" -ac 2 -c:a aac_at -b:a 128k "$A/ten minutes.m4a"

echo "==> Subtitles"
# SRT: a BOM, Windows line ends, tags, positions, cues out of order and overlapping.
printf '\xEF\xBB\xBF' > "$S/bom crlf tags.srt"
printf '1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Καλημέρα</i> <b>κόσμε</b>\r\n<font color="#ffff00">Yellow line</font>\r\n\r\n3\r\n00:00:03,000 --> 00:00:05,000\r\n{\\an8}On top, overlapping\r\n\r\n2\r\n00:00:06,000 --> 00:00:08,250\r\nLast & <u>underlined</u> 😀\r\n' >> "$S/bom crlf tags.srt"
# Greek in the old Windows encoding (what Greek subtitle sites still serve).
printf '1\n00:00:01,000 --> 00:00:02,000\nΓειά σου, τι κάνεις;\n\n2\n00:00:02,500 --> 00:00:04,000\nΌλα καλά, ευχαριστώ!\n' | iconv -f UTF-8 -t WINDOWS-1253 > "$S/greek windows-1253.srt"
# UTF-16 with a BOM; times with a dot and no hours.
printf '1\n00:00:01.000 --> 00:00:02.000\nUTF-16 Ελληνικά\n\n2\n00:00:03.000 --> 00:00:04.000\nSecond\n' | iconv -f UTF-8 -t UTF-16 > "$S/utf-16.srt"
cat > "$S/styled.vtt" <<'EOF'
WEBVTT
Kind: captions
Language: el

STYLE
::cue(.yellow) { color: yellow; }

NOTE This is a comment
that spans two lines

intro
00:01.000 --> 00:03.000 line:0 position:20% align:start
<v Νίκος>Γεια σου <c.yellow>κίτρινο</c></v>

00:00:03.500 --> 00:00:05.000
<00:00:03.500>Karaoke <00:00:04.000>words <ruby>漢<rt>kan</rt></ruby>

00:00:06.000 --> 00:00:07.000 align:end
&lt;not a tag&gt; &amp; done
EOF

echo "==> Archives"
mkdir -p "$WORK/tree/Φάκελος/empty" "$WORK/tree/deep/a/b/c/d/e"
echo "γεια" > "$WORK/tree/Φάκελος/αρχείο.txt"
echo "emoji" > "$WORK/tree/😀 smile.txt"
echo "deep" > "$WORK/tree/deep/a/b/c/d/e/file with spaces.txt"
: > "$WORK/tree/empty file.txt"
echo "hidden" > "$WORK/tree/.hidden"
ln -s "Φάκελος/αρχείο.txt" "$WORK/tree/link to file"
cp "$WORK/cover.jpg" "$WORK/tree/picture.jpg"
(cd "$WORK/tree" && /usr/bin/zip -qry "$Z/greek names.zip" .)
(cd "$WORK/tree" && /usr/bin/tar -cf "$Z/plain.tar" .)
(cd "$WORK/tree" && /usr/bin/tar -czf "$Z/squeezed.tar.gz" .)
(cd "$WORK/tree" && /usr/bin/tar -cjf "$Z/bzip.tar.bz2" .)
(cd "$WORK/tree" && /usr/bin/tar -cJf "$Z/xz.tar.xz" .)
(cd "$WORK/tree" && /usr/bin/tar -cf "$Z/seven.7z" --format 7zip .)
(cd "$WORK/tree" && /usr/bin/zip -qr -P secret "$Z/password.zip" .)
# A ZIP from Finder, with its __MACOSX extras.
(cd "$WORK/tree" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "Φάκελος" "$Z/from finder.zip")
# A ZIP whose names try to escape the folder ("zip slip").
mkdir -p "$WORK/slip/x"
echo "escaped" > "$WORK/slip/evil.txt"
(cd "$WORK/slip/x" && /usr/bin/zip -q "$Z/escape attempt.zip" ../evil.txt)
# One file squeezed on its own.
seq 1 20000 > "$WORK/numbers.txt"
gzip -c "$WORK/numbers.txt" > "$Z/numbers.txt.gz"
bzip2 -c "$WORK/numbers.txt" > "$Z/numbers.txt.bz2"
cp "/Applications/Microsoft Outlook.app/Contents/Frameworks/HxCore.framework/Versions/A/Resources/nls.7z" "$Z/real outlook.7z" 2>/dev/null || true
head -c 3000 "$Z/squeezed.tar.gz" > "$Z/damaged.tar.gz"

echo "==> Text in old encodings"
printf 'Γειά σου κόσμε!\nΑυτό είναι ένα κείμενο σε Windows-1253.\nΤιμή: 12,50 €\n' | iconv -f UTF-8 -t WINDOWS-1253 > "$D/greek windows-1253.txt"
printf 'Γειά σου κόσμε!\nISO-8859-7 κείμενο.\n' | iconv -f UTF-8 -t ISO-8859-7 > "$D/greek iso-8859-7.txt"
printf 'Привет, мир! Кириллица в Windows-1251.\n' | iconv -f UTF-8 -t WINDOWS-1251 > "$D/russian windows-1251.txt"
printf 'Ünïcödé façade naïve café — Windows-1252 “quotes”\n' | iconv -f UTF-8 -t WINDOWS-1252 > "$D/western windows-1252.txt"
printf 'UTF-16 Ελληνικά και English 😀\r\nSecond line\r\n' | iconv -f UTF-8 -t UTF-16 > "$D/utf-16 crlf.txt"
printf 'Line one\rOld Mac line ends\rThird\r' > "$D/old mac line ends.txt"
printf '名前,価格\n東京,1000\n' | iconv -f UTF-8 -t SHIFT_JIS > "$T/japanese shift-jis.csv"
printf 'Όνομα;Τιμή;Ημερομηνία\nΚαφές;3,50;24/10/2026\nΤυρί;12,90;01/02/2026\n' | iconv -f UTF-8 -t WINDOWS-1253 > "$T/greek excel windows-1253.csv"
printf '\xEF\xBB\xBF' > "$T/european semicolons.csv"
printf 'Name;Amount;Note\r\n"Smith; John";1.234,56;"He said ""hi""\r\nand left"\r\nΜαρία;-0,5;\r\n;;\r\nLast;1e3;007\r\n' >> "$T/european semicolons.csv"
printf 'a\tb\tc\n1\t2\t3\n"quoted\ttab"\tx\ty\n' > "$T/tabs.tsv"

echo "==> Done: $OUT"
