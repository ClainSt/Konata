import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccplayer/domain/text/big5_cp950_table.dart';
import 'package:ccplayer/domain/text/multibyte_text_decoder.dart';
import 'package:path/path.dart' as p;

/// 生成 Konata G01~G12 真实压缩编码微样本集（覆盖 1917~2026 番剧收藏片库压制形态）及清单。
///
/// 用法：`dart run tool/generate_codec_matrix.dart [输出目录]`
Future<void> main(List<String> args) async {
  final outDir = Directory(
    args.isNotEmpty && args.first.trim().isNotEmpty
        ? args.first.trim()
        : p.join(Directory.systemTemp.path, 'konata_codec_matrix'),
  );
  final tools = await _resolveFfmpegTools();
  final manifest = await generateCodecMatrixFixtures(
    outputDir: outDir,
    ffmpegPath: tools.ffmpeg,
    ffprobePath: tools.ffprobe,
    repoRoot: Directory.current,
  );
  final groups = manifest['groups'] as Map<String, Object?>;
  var totalBytes = 0;
  for (final entry in groups.values) {
    if (entry is Map<String, Object?> && entry['size_bytes'] is int) {
      totalBytes += entry['size_bytes']! as int;
    }
  }
  stdout.writeln(
    '已生成 G01~G12 真实压缩编码微样本集（含 WavPack/DSF 附测）：${outDir.path} '
    '（总计 ${(totalBytes / 1024.0).toStringAsFixed(1)} KiB）',
  );
  for (final entry in groups.entries) {
    final g = entry.value as Map<String, Object?>;
    final probe = g['probe_primary'] as Map<String, Object?>?;
    if (probe == null) {
      stdout.writeln('  ${entry.key}: ${g['size_bytes']} B');
      continue;
    }
    final v = probe['video'] as Map<String, Object?>;
    final audios = (probe['audios'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((a) => '${a['codec']}(${a['channels']}ch)')
        .join('+');
    stdout.writeln(
      '  ${entry.key}: ${v['codec']}/${v['profile']} ${v['pix_fmt']} '
      '${v['width']}x${v['height']} SAR=${v['sar']} DAR=${v['dar']} | '
      '$audios | 字幕=${(probe['subtitles'] as List).length} '
      '附件=${(probe['attachments'] as List).length} 章节=${probe['chapter_count']}',
    );
  }
}

/// 生成完整 G01~G12 真实压缩编码微样本并写入 `manifest.json`。
Future<Map<String, Object?>> generateCodecMatrixFixtures({
  required Directory outputDir,
  required String ffmpegPath,
  required String ffprobePath,
  required Directory repoRoot,
}) async {
  await outputDir.create(recursive: true);
  final tmpDir = Directory(p.join(outputDir.path, '_tmp'));
  await tmpDir.create(recursive: true);

  final ttfPath = _resolveTtfAttachmentPath(repoRoot);
  final groups = <String, Map<String, Object?>>{};

  // G01（主力 BDRip）：MKV + HEVC Main10 (yuv420p10le) + FLAC (2.0 & 5.1) + 外挂繁日 ASS + Chapter
  final g01Dir = Directory(p.join(outputDir.path, 'g01_bdrip'));
  await g01Dir.create(recursive: true);
  final g01Chap = File(p.join(tmpDir.path, 'g01_chapters.txt'));
  await _writeChaptersMeta(g01Chap, const [
    (0, 600, 'OP'),
    (600, 1400, 'Part A'),
    (1400, 2000, 'ED'),
  ]);
  final g01Mkv = File(p.join(g01Dir.path, 'g01_bdrip_hevc10_flac.mkv'));
  final g01Ass = File(p.join(g01Dir.path, 'g01_bdrip_hevc10_flac.tcjp.ass'));
  await _writeUtf8Ass(
    g01Ass,
    r'這是繁體中文與日本語の同時雙語字幕測試\Nこれはテスト字幕です',
  );
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-f', 'lavfi', '-i', 'anoisesrc=color=pink:amplitude=0.05:sample_rate=48000:duration=2',
    '-i', g01Chap.path,
    '-map', '0:v:0', '-map', '1:a:0', '-map', '2:a:0', '-map_chapters', '3',
    '-c:v', 'libx265', '-pix_fmt', 'yuv420p10le', '-profile:v', 'main10',
    '-preset', 'ultrafast', '-crf', '28', '-x265-params', 'log-level=error',
    '-c:a:0', 'flac', '-ac:a:0', '2',
    '-metadata:s:a:0', 'language=jpn', '-metadata:s:a:0', 'title=FLAC 2.0',
    '-c:a:1', 'flac', '-ac:a:1', '6',
    '-metadata:s:a:1', 'language=jpn', '-metadata:s:a:1', 'title=FLAC 5.1',
    g01Mkv.path,
  ]);
  // 额外生成 8 秒连续无章节切换的真实 HEVC Main10 + FLAC 稳态样本，供 OSD 3 秒自动隐藏后 >=2 秒零帧实测使用。
  final g01Steady = File(p.join(g01Dir.path, 'g01_steady_hevc10_flac_8s.mkv'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=8',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=8',
    '-c:v', 'libx265', '-pix_fmt', 'yuv420p10le', '-profile:v', 'main10',
    '-preset', 'ultrafast', '-crf', '32', '-x265-params', 'log-level=error',
    '-c:a', 'flac', '-ac', '2',
    g01Steady.path,
  ]);
  groups['G01'] = {
    'primary': _relPosix(outputDir, g01Mkv),
    'steady_8s': _relPosix(outputDir, g01Steady),
    'sidecars': [_relPosix(outputDir, g01Ass)],
    'size_bytes': await g01Mkv.length(),
  };

  // G02（主力 WEBRip）：MKV + HEVC Main10 + AAC + 内封简繁双 ASS + 内封 .ttf 字体附件
  final g02Dir = Directory(p.join(outputDir.path, 'g02_webrip'));
  await g02Dir.create(recursive: true);
  final g02Sc = File(p.join(tmpDir.path, 'g02_sc.ass'));
  final g02Tc = File(p.join(tmpDir.path, 'g02_tc.ass'));
  await _writeUtf8Ass(g02Sc, '简体中文字幕内封测试（WEBRip HEVC Main10）');
  await _writeUtf8Ass(g02Tc, '繁體中文字幕內封測試（WEBRip HEVC Main10）');
  final g02Mkv = File(p.join(g02Dir.path, 'g02_webrip_hevc10_aac_fonts.mkv'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=523:sample_rate=48000:duration=2',
    '-i', g02Sc.path,
    '-i', g02Tc.path,
    '-map', '0:v:0', '-map', '1:a:0', '-map', '2:s:0', '-map', '3:s:0',
    '-c:v', 'libx265', '-pix_fmt', 'yuv420p10le', '-profile:v', 'main10',
    '-preset', 'ultrafast', '-crf', '28', '-x265-params', 'log-level=error',
    '-c:a', 'aac', '-b:a', '128k', '-ac', '2',
    '-c:s', 'ass',
    '-metadata:s:s:0', 'language=chi', '-metadata:s:s:0', 'title=简体中文',
    '-metadata:s:s:1', 'language=chi', '-metadata:s:s:1', 'title=繁體中文',
    '-attach', ttfPath,
    '-metadata:s:t:0', 'mimetype=application/x-truetype-font',
    g02Mkv.path,
  ]);
  groups['G02'] = {
    'primary': _relPosix(outputDir, g02Mkv),
    'size_bytes': await g02Mkv.length(),
  };

  // G03（Opus 新番）：MKV + HEVC Main10 + Opus (2.0 & 5.1) + 命名 OP/ED 章节
  final g03Dir = Directory(p.join(outputDir.path, 'g03_opus'));
  await g03Dir.create(recursive: true);
  final g03Chap = File(p.join(tmpDir.path, 'g03_chapters.txt'));
  await _writeChaptersMeta(g03Chap, const [
    (0, 650, 'Opening'),
    (650, 1450, 'Main Story'),
    (1450, 2000, 'Ending'),
  ]);
  final g03Mkv = File(p.join(g03Dir.path, 'g03_hevc10_opus_multi.mkv'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=48000:duration=2',
    '-i', g03Chap.path,
    '-filter_complex', '[2:a]aformat=channel_layouts=5.1[a51]',
    '-map', '0:v:0', '-map', '1:a:0', '-map', '[a51]', '-map_chapters', '3',
    '-c:v', 'libx265', '-pix_fmt', 'yuv420p10le', '-profile:v', 'main10',
    '-preset', 'ultrafast', '-crf', '28', '-x265-params', 'log-level=error',
    '-c:a:0', 'libopus', '-b:a:0', '128k', '-ac:a:0', '2',
    '-metadata:s:a:0', 'title=Opus 2.0',
    '-c:a:1', 'libopus', '-b:a:1', '256k', '-mapping_family:a:1', '1',
    '-metadata:s:a:1', 'title=Opus 5.1',
    g03Mkv.path,
  ]);
  groups['G03'] = {
    'primary': _relPosix(outputDir, g03Mkv),
    'size_bytes': await g03Mkv.length(),
  };

  // G04（8-bit 主力）：MKV + H.264 High 8-bit + FLAC，MP4 + H.264 High 8-bit + AAC
  final g04Dir = Directory(p.join(outputDir.path, 'g04_h264_8bit'));
  await g04Dir.create(recursive: true);
  final g04Mkv = File(p.join(g04Dir.path, 'g04_h264_high8_flac.mkv'));
  final g04Mp4 = File(p.join(g04Dir.path, 'g04_h264_high8_aac.mp4'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-profile:v', 'high',
    '-preset', 'veryfast', '-crf', '26',
    '-c:a', 'flac', '-ac', '2',
    g04Mkv.path,
  ]);
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-profile:v', 'high',
    '-preset', 'veryfast', '-crf', '26',
    '-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-movflags', '+faststart',
    g04Mp4.path,
  ]);
  groups['G04'] = {
    'primary': _relPosix(outputDir, g04Mkv),
    'secondary': _relPosix(outputDir, g04Mp4),
    'size_bytes': await g04Mkv.length() + await g04Mp4.length(),
  };

  // G05（Hi10P 杀手组）：MKV + H.264 High 10 (yuv420p10le) + FLAC + 真实 BIG5 (CP950) 外挂繁中 ASS
  final g05Dir = Directory(p.join(outputDir.path, 'g05_hi10p'));
  await g05Dir.create(recursive: true);
  final g05Mkv = File(p.join(g05Dir.path, 'g05_h264_hi10p_flac.mkv'));
  final g05Ass = File(p.join(g05Dir.path, 'g05_h264_hi10p_flac.big5.ass'));
  await _writeBig5Ass(
    g05Ass,
    '電影院裡的皇后與頭髮乾乾淨淨，臺灣動畫收藏庫驚鴻一瞥、鬱鬱寡歡與鐘錶店老闆',
  );
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=494:sample_rate=48000:duration=2',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p10le', '-profile:v', 'high10',
    '-preset', 'ultrafast', '-crf', '26',
    '-c:a', 'flac', '-ac', '2',
    g05Mkv.path,
  ]);
  groups['G05'] = {
    'primary': _relPosix(outputDir, g05Mkv),
    'sidecars': [_relPosix(outputDir, g05Ass)],
    'size_bytes': await g05Mkv.length(),
  };

  // G06（12-bit 4K 组）：MKV + 2160p HEVC Main12 (yuv420p12le) + FLAC
  final g06Dir = Directory(p.join(outputDir.path, 'g06_hevc_main12_4k'));
  await g06Dir.create(recursive: true);
  final g06Mkv = File(p.join(g06Dir.path, 'g06_2160p_hevc_main12_flac.mkv'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi',
    '-i', "color=c=0x223355:size=3840x2160:rate=24:duration=1.5,geq=lum='mod(X/16+N*8,255)':cb=128:cr=128",
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=1.5',
    '-c:v', 'libx265', '-pix_fmt', 'yuv420p12le', '-profile:v', 'main12',
    '-preset', 'ultrafast', '-crf', '34', '-x265-params', 'log-level=error',
    '-c:a', 'flac', '-ac', '2',
    g06Mkv.path,
  ]);
  groups['G06'] = {
    'primary': _relPosix(outputDir, g06Mkv),
    'size_bytes': await g06Mkv.length(),
  };

  // G07（4:4:4 Rext + VFR 组）：MKV + HEVC Rext (yuv444p10le, 24/60fps 真实混帧) + FLAC
  final g07Dir = Directory(p.join(outputDir.path, 'g07_hevc_rext_vfr'));
  await g07Dir.create(recursive: true);
  final g07Part24 = File(p.join(tmpDir.path, 'g07_24.mkv'));
  final g07Part60 = File(p.join(tmpDir.path, 'g07_60.mkv'));
  final g07List = File(p.join(tmpDir.path, 'g07_concat.txt'));
  final g07Mkv = File(p.join(g07Dir.path, 'g07_hevc_rext_444p10_vfr.mkv'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=1',
    '-c:v', 'libx265', '-pix_fmt', 'yuv444p10le', '-profile:v', 'main444-10',
    '-preset', 'ultrafast', '-crf', '28', '-x265-params', 'log-level=error',
    g07Part24.path,
  ]);
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=60:duration=1',
    '-c:v', 'libx265', '-pix_fmt', 'yuv444p10le', '-profile:v', 'main444-10',
    '-preset', 'ultrafast', '-crf', '28', '-x265-params', 'log-level=error',
    g07Part60.path,
  ]);
  final p24 = g07Part24.path.replaceAll('\\', '/');
  final p60 = g07Part60.path.replaceAll('\\', '/');
  await g07List.writeAsString("file '$p24'\nfile '$p60'\n", encoding: utf8);
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'concat', '-safe', '0', '-i', g07List.path,
    '-f', 'lavfi', '-i', 'sine=frequency=587:sample_rate=48000:duration=2',
    '-map', '0:v:0', '-map', '1:a:0',
    '-c:v', 'copy', '-fps_mode', 'passthrough',
    '-c:a', 'flac', '-ac', '2',
    g07Mkv.path,
  ]);
  groups['G07'] = {
    'primary': _relPosix(outputDir, g07Mkv),
    'size_bytes': await g07Mkv.length(),
  };

  // G08（AV1 组）：MKV (AV1 10-bit + FLAC) 与 WebM (AV1 8-bit + Opus)
  final g08Dir = Directory(p.join(outputDir.path, 'g08_av1'));
  await g08Dir.create(recursive: true);
  final g08Mkv = File(p.join(g08Dir.path, 'g08_av1_10bit_flac.mkv'));
  final g08Webm = File(p.join(g08Dir.path, 'g08_av1_8bit_opus.webm'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-c:v', 'libsvtav1', '-pix_fmt', 'yuv420p10le', '-preset', '10', '-crf', '36',
    '-c:a', 'flac', '-ac', '2',
    g08Mkv.path,
  ]);
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-c:v', 'libsvtav1', '-pix_fmt', 'yuv420p', '-preset', '10', '-crf', '36',
    '-c:a', 'libopus', '-b:a', '128k', '-ac', '2',
    g08Webm.path,
  ]);
  groups['G08'] = {
    'primary': _relPosix(outputDir, g08Mkv),
    'secondary': _relPosix(outputDir, g08Webm),
    'size_bytes': await g08Mkv.length() + await g08Webm.length(),
  };

  // G09（4K HDR + TrueHD + PGS 组）：MKV + M2TS (2160p BT.2020 PQ + TrueHD 5.1/AC3 + 内封 PGS .sup)
  final g09Dir = Directory(p.join(outputDir.path, 'g09_hdr10_truehd_pgs'));
  await g09Dir.create(recursive: true);
  final g09Sup = File(p.join(tmpDir.path, 'g09_pgs.sup'));
  await _writeMinimalPgsSup(g09Sup, width: 3840, height: 2160);
  final g09Mkv = File(p.join(g09Dir.path, 'g09_2160p_hdr10_truehd_pgs.mkv'));
  final g09M2ts = File(p.join(g09Dir.path, 'g09_2160p_hdr10_ac3_pgs.m2ts'));
  const hdrParams =
      'log-level=error:hdr-opt=1:repeat-headers=1:colorprim=bt2020:'
      'transfer=smpte2084:colormatrix=bt2020nc:'
      'master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):'
      'max-cll=1000,400';
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi',
    '-i', "color=c=0x402060:size=3840x2160:rate=24:duration=1.5,geq=lum='mod(X/16+N*6,255)':cb=128:cr=128",
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=1.5',
    '-i', g09Sup.path,
    '-filter_complex', '[1:a]aformat=channel_layouts=5.1(side)[a51]',
    '-map', '0:v:0', '-map', '[a51]', '-map', '2:s:0',
    '-c:v', 'libx265', '-pix_fmt', 'yuv420p10le', '-profile:v', 'main10',
    '-preset', 'ultrafast', '-crf', '34',
    '-color_primaries', 'bt2020', '-color_trc', 'smpte2084', '-colorspace', 'bt2020nc',
    '-x265-params', hdrParams,
    '-c:a', 'truehd', '-strict', '-2',
    '-c:s', 'copy',
    g09Mkv.path,
  ]);
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-i', g09Mkv.path,
    '-map', '0:v:0', '-map', '0:a:0', '-map', '0:s:0',
    '-c:v', 'copy', '-c:a', 'ac3', '-b:a', '448k', '-ac', '6', '-c:s', 'copy',
    '-f', 'mpegts',
    g09M2ts.path,
  ]);
  groups['G09'] = {
    'primary': _relPosix(outputDir, g09Mkv),
    'secondary': _relPosix(outputDir, g09M2ts),
    'size_bytes': await g09Mkv.length() + await g09M2ts.length(),
  };

  // G10（DTS / AC3 / E-AC3 环绕组）：三音轨无缝热切验证
  final g10Dir = Directory(p.join(outputDir.path, 'g10_surround_dts_ac3'));
  await g10Dir.create(recursive: true);
  final g10Mkv = File(p.join(g10Dir.path, 'g10_dts_ac3_eac3_51.mkv'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=554:sample_rate=48000:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=659:sample_rate=48000:duration=2',
    '-filter_complex',
    '[1:a]aformat=channel_layouts=5.1(side)[a1];[2:a]aformat=channel_layouts=5.1[a2];[3:a]aformat=channel_layouts=5.1[a3]',
    '-map', '0:v:0', '-map', '[a1]', '-map', '[a2]', '-map', '[a3]',
    '-c:v', 'libx265', '-pix_fmt', 'yuv420p10le', '-profile:v', 'main10',
    '-preset', 'ultrafast', '-crf', '28', '-x265-params', 'log-level=error',
    '-c:a:0', 'dca', '-strict', '-2', '-b:a:0', '768k', '-metadata:s:a:0', 'title=DTS 5.1',
    '-c:a:1', 'ac3', '-b:a:1', '448k', '-metadata:s:a:1', 'title=AC3 5.1',
    '-c:a:2', 'eac3', '-b:a:2', '448k', '-metadata:s:a:2', 'title=E-AC3 5.1',
    g10Mkv.path,
  ]);
  groups['G10'] = {
    'primary': _relPosix(outputDir, g10Mkv),
    'size_bytes': await g10Mkv.length(),
  };

  // G11（ALAC 无损组）：MKV 内封 ALAC + 同目录外挂 .m4a (ALAC)
  final g11Dir = Directory(p.join(outputDir.path, 'g11_alac'));
  await g11Dir.create(recursive: true);
  final g11Mkv = File(p.join(g11Dir.path, 'g11_alac_lossless.mkv'));
  final g11M4a = File(p.join(g11Dir.path, 'g11_alac_lossless.commentary.m4a'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-profile:v', 'high',
    '-preset', 'veryfast', '-crf', '26',
    '-c:a', 'alac', '-ac', '2',
    g11Mkv.path,
  ]);
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=48000:duration=2',
    '-c:a', 'alac', '-ac', '2',
    g11M4a.path,
  ]);
  groups['G11'] = {
    'primary': _relPosix(outputDir, g11Mkv),
    'sidecars': [_relPosix(outputDir, g11M4a)],
    'size_bytes': await g11Mkv.length() + await g11M4a.length(),
  };

  // G12（老番变形 DVD 720x480 SAR 32:27 -> DAR 16:9 + 尾部 moov MP4 远程 Range 秒开验证）
  final g12Dir = Directory(p.join(outputDir.path, 'g12_dvd_and_tail_moov'));
  await g12Dir.create(recursive: true);
  final g12Dvd = File(p.join(g12Dir.path, 'g12_dvd_720x480_sar32x27_ac3_mp3.mkv'));
  final g12Mp4 = File(p.join(g12Dir.path, 'g12_tail_moov_stream.mp4'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=720x480:rate=24:duration=2,setsar=32/27',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=2',
    '-f', 'lavfi', '-i', 'sine=frequency=523:sample_rate=48000:duration=2',
    '-map', '0:v:0', '-map', '1:a:0', '-map', '2:a:0',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-profile:v', 'high',
    '-preset', 'veryfast', '-crf', '26',
    '-c:a:0', 'ac3', '-b:a:0', '192k', '-ac:a:0', '2',
    '-c:a:1', 'libmp3lame', '-b:a:1', '192k', '-ac:a:1', '2',
    g12Dvd.path,
  ]);
  // 使用轻度动态噪点确保 5 秒 720x480 尾部 moov MP4 真实体积 >= 6 MiB（远大于 1 MiB 首窗），
  // 从而在 LocalStreamBridge 实测中清晰区分首尾 Range 秒开与整文件顺序读取。
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=720x480:rate=24:duration=5,noise=alls=22:allf=t,setsar=32/27',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=5',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-profile:v', 'high',
    '-preset', 'veryfast', '-b:v', '12000k', '-maxrate', '14000k', '-bufsize', '14000k',
    '-c:a', 'aac', '-b:a', '128k', '-ac', '2',
    g12Mp4.path,
  ]);
  final moovCheck = await _inspectMp4MoovPlacement(g12Mp4);
  if (moovCheck['moov_after_mdat'] != true) {
    throw StateError('G12 尾部 moov MP4 生成异常，moov 未位于 mdat 之后：$moovCheck');
  }
  groups['G12'] = {
    'primary': _relPosix(outputDir, g12Dvd),
    'secondary': _relPosix(outputDir, g12Mp4),
    'tail_moov_check': moovCheck,
    'size_bytes': await g12Dvd.length() + await g12Mp4.length(),
  };

  // 附测无损音轨：WavPack (.wv) 与 DSD64 (.dsf)
  final bonusDir = Directory(p.join(outputDir.path, 'audio_bonus'));
  await bonusDir.create(recursive: true);
  final bonusWv = File(p.join(bonusDir.path, 'bonus_wavpack.wv'));
  final bonusDsf = File(p.join(bonusDir.path, 'bonus_dsd64.dsf'));
  await _runFfmpeg(ffmpegPath, [
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=1.5',
    '-c:a', 'wavpack', '-ac', '2',
    bonusWv.path,
  ]);
  await _writeMinimalDsf(bonusDsf, durationSeconds: 1.5);
  groups['AUDIO_BONUS'] = {
    'wavpack': _relPosix(outputDir, bonusWv),
    'dsf': _relPosix(outputDir, bonusDsf),
    'size_bytes': await bonusWv.length() + await bonusDsf.length(),
  };

  // 使用 ffprobe 客观采集每组主/副素材的容器与编解码器元数据。
  for (final entry in groups.entries) {
    if (entry.key == 'AUDIO_BONUS') continue;
    final primaryRel = entry.value['primary']! as String;
    entry.value['probe_primary'] = await _probeMediaSummary(
      ffprobePath,
      File(p.join(outputDir.path, primaryRel)),
    );
    final secondaryRel = entry.value['secondary'] as String?;
    if (secondaryRel != null) {
      entry.value['probe_secondary'] = await _probeMediaSummary(
        ffprobePath,
        File(p.join(outputDir.path, secondaryRel)),
      );
    }
  }

  if (await tmpDir.exists()) {
    await tmpDir.delete(recursive: true);
  }

  final manifest = <String, Object?>{
    'ffmpeg': ffmpegPath,
    'generated_at': DateTime.now().toIso8601String(),
    'groups': groups,
  };
  final manifestFile = File(p.join(outputDir.path, 'manifest.json'));
  await manifestFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(manifest),
    encoding: utf8,
  );
  return manifest;
}

Future<({String ffmpeg, String ffprobe})> _resolveFfmpegTools() async {
  final envBin = (Platform.environment['FFMPEG_BIN'] ?? '').trim();
  final candidates = <String>[
    if (envBin.isNotEmpty) envBin,
    r'D:\工具\ffmpeg\bin\ffmpeg.exe',
  ];
  final whereCmd = Platform.isWindows ? 'where' : 'which';
  try {
    final res = await Process.run(whereCmd, ['ffmpeg']);
    if (res.exitCode == 0) {
      final first = res.stdout.toString().split(RegExp(r'\r?\n')).first.trim();
      if (first.isNotEmpty) candidates.insert(0, first);
    }
  } catch (_) {
    // 环境变量未命中时继续按候选路径探测。
  }

  String? ffmpeg;
  for (final c in candidates) {
    if (await File(c).exists()) {
      ffmpeg = c;
      break;
    }
  }
  if (ffmpeg == null) {
    throw StateError('未找到 ffmpeg 可执行文件（请设置 FFMPEG_BIN 或加入 PATH）');
  }
  final probeName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
  final siblingProbe = p.join(p.dirname(ffmpeg), probeName);
  final ffprobe = await File(siblingProbe).exists() ? siblingProbe : probeName;
  return (ffmpeg: ffmpeg, ffprobe: ffprobe);
}

String _resolveTtfAttachmentPath(Directory repoRoot) {
  final candidates = [
    r'C:\Windows\Fonts\marlett.ttf',
    r'C:\Windows\Fonts\lucon.ttf',
    p.join(repoRoot.path, 'assets', 'fonts', 'InterVariable.ttf'),
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  throw StateError('未找到可供 G02 内封的 TTF 字体附件');
}

String _relPosix(Directory root, File file) {
  return p.relative(file.path, from: root.path).replaceAll('\\', '/');
}

Future<void> _runFfmpeg(String ffmpegPath, List<String> args) async {
  final res = await Process.run(
    ffmpegPath,
    args,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (res.exitCode != 0) {
    throw StateError(
      'ffmpeg 执行失败 (exit=${res.exitCode}): ${args.join(' ')}\n${res.stderr}',
    );
  }
}

Future<void> _writeChaptersMeta(
  File file,
  List<(int startMs, int endMs, String title)> chapters,
) async {
  final buf = StringBuffer(';FFMETADATA1\n');
  for (final c in chapters) {
    buf
      ..writeln('[CHAPTER]')
      ..writeln('TIMEBASE=1/1000')
      ..writeln('START=${c.$1}')
      ..writeln('END=${c.$2}')
      ..writeln('title=${c.$3}');
  }
  await file.writeAsString(buf.toString(), encoding: utf8);
}

String _buildAssDocument(String dialogueText) {
  return '[Script Info]\n'
      'ScriptType: v4.00+\n'
      'PlayResX: 640\n'
      'PlayResY: 360\n\n'
      '[V4+ Styles]\n'
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, '
      'Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
      'Alignment, MarginL, MarginR, MarginV, Encoding\n'
      'Style: Default,Arial,24,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,1.5,0,2,10,10,16,1\n\n'
      '[Events]\n'
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
      'Dialogue: 0,0:00:00.10,0:00:01.90,Default,,0,0,0,,$dialogueText\n';
}

Future<void> _writeUtf8Ass(File file, String dialogueText) async {
  await file.writeAsString(_buildAssDocument(dialogueText), encoding: utf8);
}

/// 基于领域层完整标准 CP950 码表反向编码生成真实 Big5 字节流，并做零 `U+FFFD` 往返核验。
Future<void> _writeBig5Ass(File file, String dialogueText) async {
  final table = Big5Cp950Table.ensureTableForVerification();
  final reverse = <int, (int, int)>{};
  for (var lead = 0x81; lead <= 0xFE; lead++) {
    for (var idx = 0; idx < 157; idx++) {
      final cp = table[(lead - 0x81) * 157 + idx];
      if (cp == 0 || reverse.containsKey(cp)) continue;
      final trail = idx < 63 ? (0x40 + idx) : (0xA1 + (idx - 63));
      reverse[cp] = (lead, trail);
    }
  }
  final doc = _buildAssDocument(dialogueText);
  final out = BytesBuilder(copy: false);
  for (final rune in doc.runes) {
    if (rune < 0x80) {
      out.addByte(rune);
      continue;
    }
    final pair = reverse[rune];
    if (pair == null) {
      throw StateError('字符 U+${rune.toRadixString(16)} 未在标准 Big5/CP950 码表中找到');
    }
    out
      ..addByte(pair.$1)
      ..addByte(pair.$2);
  }
  final bytes = out.takeBytes();
  final roundTrip = MultibyteTextDecoder.decodeBytes(bytes);
  if (roundTrip.contains('\uFFFD') || !roundTrip.contains(dialogueText)) {
    throw StateError('生成的 G05 Big5 字幕未能无损往返解码');
  }
  await file.writeAsBytes(bytes, flush: true);
}

/// 生成符合蓝光 PGS 规范的图形字幕 `.sup` 二进制包（含展示与清屏两组段）。
Future<void> _writeMinimalPgsSup(
  File file, {
  required int width,
  required int height,
}) async {
  Uint8List segment(int pts90k, int segType, Uint8List payload) {
    final buf = Uint8List(13 + payload.length);
    final bd = ByteData.sublistView(buf);
    buf[0] = 0x50; // P
    buf[1] = 0x47; // G
    bd.setUint32(2, pts90k, Endian.big);
    bd.setUint32(6, 0, Endian.big);
    buf[10] = segType;
    bd.setUint16(11, payload.length, Endian.big);
    buf.setRange(13, buf.length, payload);
    return buf;
  }

  const objW = 64;
  const objH = 16;
  final objX = (width - objW) ~/ 2;
  final objY = height - 120;
  final rle = BytesBuilder(copy: false);
  for (var row = 0; row < objH; row++) {
    rle.add(const [0x00, 0xC0, objW, 0x01, 0x00, 0x00]);
  }
  final rleBytes = rle.takeBytes();

  final ptsShow = (0.15 * 90000).round();
  final pcsShow = Uint8List(19);
  final pcsBd = ByteData.sublistView(pcsShow);
  pcsBd.setUint16(0, width, Endian.big);
  pcsBd.setUint16(2, height, Endian.big);
  pcsShow[4] = 0x10;
  pcsBd.setUint16(5, 1, Endian.big);
  pcsShow[7] = 0x80;
  pcsShow[8] = 0x00;
  pcsShow[9] = 0x00;
  pcsShow[10] = 1;
  pcsBd.setUint16(11, 0, Endian.big);
  pcsShow[13] = 0;
  pcsShow[14] = 0;
  pcsBd.setUint16(15, objX, Endian.big);
  pcsBd.setUint16(17, objY, Endian.big);

  final wds = Uint8List(10);
  final wdsBd = ByteData.sublistView(wds);
  wds[0] = 1;
  wds[1] = 0;
  wdsBd.setUint16(2, objX, Endian.big);
  wdsBd.setUint16(4, objY, Endian.big);
  wdsBd.setUint16(6, objW, Endian.big);
  wdsBd.setUint16(8, objH, Endian.big);

  final pds = Uint8List.fromList(const [
    0, 0,
    0, 16, 128, 128, 0,
    1, 235, 128, 128, 255,
  ]);

  final dataLen = 4 + rleBytes.length;
  final ods = Uint8List(11 + rleBytes.length);
  final odsBd = ByteData.sublistView(ods);
  odsBd.setUint16(0, 0, Endian.big);
  ods[2] = 0;
  ods[3] = 0xC0;
  ods[4] = (dataLen >> 16) & 0xFF;
  ods[5] = (dataLen >> 8) & 0xFF;
  ods[6] = dataLen & 0xFF;
  odsBd.setUint16(7, objW, Endian.big);
  odsBd.setUint16(9, objH, Endian.big);
  ods.setRange(11, ods.length, rleBytes);

  final ptsClear = (1.35 * 90000).round();
  final pcsClear = Uint8List(11);
  final pcsClearBd = ByteData.sublistView(pcsClear);
  pcsClearBd.setUint16(0, width, Endian.big);
  pcsClearBd.setUint16(2, height, Endian.big);
  pcsClear[4] = 0x10;
  pcsClearBd.setUint16(5, 2, Endian.big);
  pcsClear[7] = 0x00;

  final blob = BytesBuilder(copy: false)
    ..add(segment(ptsShow, 0x16, pcsShow))
    ..add(segment(ptsShow, 0x17, wds))
    ..add(segment(ptsShow, 0x14, pds))
    ..add(segment(ptsShow, 0x15, ods))
    ..add(segment(ptsShow, 0x80, Uint8List(0)))
    ..add(segment(ptsClear, 0x16, pcsClear))
    ..add(segment(ptsClear, 0x80, Uint8List(0)));
  await file.writeAsBytes(blob.takeBytes(), flush: true);
}

/// 生成标准 DSD64（2.8224 MHz 立体声）`.dsf` 无损音频样本。
Future<void> _writeMinimalDsf(
  File file, {
  required double durationSeconds,
}) async {
  const sampleRate = 2822400;
  const channels = 2;
  const blockSize = 4096;
  final bitsPerChannel = (sampleRate * durationSeconds).round();
  final bytesPerChannel = (bitsPerChannel + 7) ~/ 8;
  final blocksPerChannel = (bytesPerChannel + blockSize - 1) ~/ blockSize;
  final totalSamples = blocksPerChannel * blockSize * 8;
  final dataBytes = blocksPerChannel * blockSize * channels;
  final totalFileSize = 28 + 52 + 12 + dataBytes;

  final header = Uint8List(92);
  final bd = ByteData.sublistView(header);
  header.setRange(0, 4, ascii.encode('DSD '));
  bd.setUint64(4, 28, Endian.little);
  bd.setUint64(12, totalFileSize, Endian.little);
  bd.setUint64(20, 0, Endian.little);

  header.setRange(28, 32, ascii.encode('fmt '));
  bd.setUint64(32, 52, Endian.little);
  bd.setUint32(40, 1, Endian.little);
  bd.setUint32(44, 0, Endian.little);
  bd.setUint32(48, 2, Endian.little);
  bd.setUint32(52, channels, Endian.little);
  bd.setUint32(56, sampleRate, Endian.little);
  bd.setUint32(60, 1, Endian.little);
  bd.setUint64(64, totalSamples, Endian.little);
  bd.setUint32(72, blockSize, Endian.little);
  bd.setUint32(76, 0, Endian.little);

  header.setRange(80, 84, ascii.encode('data'));
  bd.setUint64(84, 12 + dataBytes, Endian.little);

  final idleBlock = Uint8List(blockSize)..fillRange(0, blockSize, 0x69);
  final sink = file.openWrite();
  sink.add(header);
  for (var i = 0; i < blocksPerChannel * channels; i++) {
    sink.add(idleBlock);
  }
  await sink.flush();
  await sink.close();
}

Future<Map<String, Object?>> _inspectMp4MoovPlacement(File file) async {
  final data = await file.readAsBytes();
  final bd = ByteData.sublistView(data);
  var pos = 0;
  var moovOffset = -1;
  var mdatOffset = -1;
  final boxes = <Map<String, Object>>[];
  while (pos + 8 <= data.length) {
    var size = bd.getUint32(pos, Endian.big);
    final tag = ascii.decode(data.sublist(pos + 4, pos + 8), allowInvalid: true);
    if (size == 1 && pos + 16 <= data.length) {
      size = bd.getUint64(pos + 8, Endian.big);
    } else if (size == 0) {
      size = data.length - pos;
    }
    boxes.add({'type': tag, 'offset': pos, 'size': size});
    if (tag == 'moov') moovOffset = pos;
    if (tag == 'mdat') mdatOffset = pos;
    if (size < 8) break;
    pos += size;
  }
  return {
    'file_size': data.length,
    'moov_offset': moovOffset,
    'mdat_offset': mdatOffset,
    'moov_after_mdat': moovOffset > mdatOffset && mdatOffset >= 0,
    'moov_offset_ratio': data.isNotEmpty && moovOffset >= 0
        ? double.parse((moovOffset / data.length).toStringAsFixed(4))
        : 0.0,
    'boxes': boxes,
  };
}

Future<Map<String, Object?>> _probeMediaSummary(
  String ffprobePath,
  File file,
) async {
  final res = await Process.run(
    ffprobePath,
    [
      '-v', 'quiet',
      '-print_format', 'json',
      '-show_format',
      '-show_streams',
      '-show_chapters',
      file.path,
    ],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (res.exitCode != 0) {
    throw StateError('ffprobe 探测失败 (${file.path}): ${res.stderr}');
  }
  final raw = jsonDecode(res.stdout.toString()) as Map<String, Object?>;
  final streams = ((raw['streams'] as List<Object?>?) ?? const [])
      .cast<Map<String, Object?>>();
  final video = streams.firstWhere(
    (s) => s['codec_type'] == 'video',
    orElse: () => const <String, Object?>{},
  );
  final audios = streams
      .where((s) => s['codec_type'] == 'audio')
      .map(
        (s) => <String, Object?>{
          'codec': s['codec_name'],
          'channels': s['channels'],
          'layout': s['channel_layout'],
          'sample_rate': s['sample_rate'],
        },
      )
      .toList(growable: false);
  final subtitles = streams
      .where((s) => s['codec_type'] == 'subtitle')
      .map(
        (s) => <String, Object?>{
          'codec': s['codec_name'],
          'title': (s['tags'] as Map<String, Object?>?)?['title'] ?? '',
        },
      )
      .toList(growable: false);
  final attachments = streams
      .where((s) => s['codec_type'] == 'attachment')
      .map((s) => (s['tags'] as Map<String, Object?>?)?['filename'] ?? '')
      .toList(growable: false);
  final format = (raw['format'] as Map<String, Object?>?) ?? const {};
  final chapters = (raw['chapters'] as List<Object?>?) ?? const [];
  return {
    'format': format['format_name'],
    'duration': format['duration'],
    'video': {
      'codec': video['codec_name'],
      'profile': video['profile'],
      'pix_fmt': video['pix_fmt'],
      'width': video['width'],
      'height': video['height'],
      'sar': video['sample_aspect_ratio'],
      'dar': video['display_aspect_ratio'],
      'color_primaries': video['color_primaries'],
      'color_transfer': video['color_transfer'],
      'color_space': video['color_space'],
    },
    'audios': audios,
    'subtitles': subtitles,
    'attachments': attachments,
    'chapter_count': chapters.length,
  };
}
