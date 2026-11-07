// Explicit read-only inventory of selected works in the Windows library.
// Credentials stay in memory; ffprobe sees only a temporary loopback address.
import 'dart:convert';
import 'dart:io';

import 'package:ccplayer/core/sources.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/webdav_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const ffprobe = String.fromEnvironment('BDRIP_FFPROBE');
  const output = String.fromEnvironment('BDRIP_SOURCE_REPORT');
  const selectedTitles = String.fromEnvironment('BDRIP_TITLES');
  const selectedFile = String.fromEnvironment('BDRIP_FILE_CONTAINS');
  const clipDirectory = String.fromEnvironment('BDRIP_CLIP_DIRECTORY');
  const ffmpeg = String.fromEnvironment('BDRIP_FFMPEG');
  testWidgets(
    'probe one main file per explicitly selected work',
    (_) async {
      sqfliteFfiInit();
      final reportFile = File(output);
      expect(
        await reportFile.exists(),
        isFalse,
        reason:
            'Choose a new evidence path; do not overwrite previous results.',
      );
      final db = await databaseFactoryFfi.openDatabase(
        p.join(
          Platform.environment['APPDATA']!,
          'com.clainst',
          'Konata',
          'ccplayer.db',
        ),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final results = <Map<String, Object?>>[];
      final credentials = <String, Map<String, Object?>>{};
      try {
        for (final title in [
          '地狱乐',
          '凹凸魔女的母女故事',
          '记录的地平线 圆桌崩坏',
          '四叠半时光机布鲁斯',
          '牙斗兽娘',
          '数码宝贝大冒险 tri. 第六章「我们的未来」',
          '蓝色管弦乐',
          '章鱼哔的原罪',
          '铃芽之旅',
        ]) {
          if (selectedTitles.isNotEmpty &&
              !selectedTitles.split(',').contains(title)) {
            continue;
          }
          final rows = await db.rawQuery(
            'SELECT s.*, a.relative_path AS asset_path, a.name AS asset_name '
            'FROM assets a JOIN works w ON a.work_id=w.id '
            'JOIN sources s ON a.source_id=s.id '
            'WHERE w.title=? AND a.category=? AND s.kind=? '
            'AND instr(a.name, ?) > 0 '
            'ORDER BY a.relative_path LIMIT 1',
            [title, 'main', 'webdav', selectedFile],
          );
          if (rows.isEmpty) {
            results.add({'title': title, 'status': 'missing'});
            continue;
          }
          final source = rows.single;
          Process? process;
          HttpServer? server;
          WebDavStream? relay;
          try {
            final id = source['id'] as String;
            // Read once per source for this bounded test session.
            final auth = credentials[id] ??= await Catalog.instance
                .withCredentials(source);
            final dav = WebDav(auth);
            relay = WebDavStream(
              target: dav.fileUri(source['asset_path'] as String),
              username: dav.username,
              password: dav.password,
              authorization: dav.username.isEmpty ? null : dav.auth,
            );
            server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            final activeRelay = relay;
            server.listen((request) async {
              if (request.uri.path != '/probe' ||
                  !['GET', 'HEAD'].contains(request.method)) {
                request.response.statusCode = 404;
                await request.response.close();
                return;
              }
              await activeRelay.serve(request);
            });
            process = await Process.start(ffprobe, [
              '-v',
              'error',
              '-rw_timeout',
              '15000000',
              '-probesize',
              '5242880',
              '-analyzeduration',
              '3000000',
              '-show_entries',
              'stream=index,codec_type,codec_name,profile,pix_fmt,bits_per_raw_sample,'
                  'bits_per_sample,width,height,r_frame_rate,avg_frame_rate,field_order,'
                  'sample_aspect_ratio,color_range,color_space,color_transfer,color_primaries,'
                  'sample_fmt,sample_rate,channels,channel_layout:'
                  'stream_tags=language,title:format=duration,size,bit_rate',
              '-of',
              'json',
              'http://127.0.0.1:${server.port}/probe',
            ]);
            final stdout = process.stdout.transform(utf8.decoder).join();
            final stderr = process.stderr.transform(utf8.decoder).join();
            final exit = await process.exitCode.timeout(
              const Duration(seconds: 45),
            );
            final text = await stdout;
            final errors = await stderr;
            final status = RegExp(r'HTTP error (\d{3})').firstMatch(errors);
            final result = <String, Object?>{
              'title': title, 'file': source['asset_name'],
              'status': exit == 0 ? 'probed' : 'failed', 'exit_code': exit,
              if (status != null) 'http_status': status.group(1),
              if (exit == 0) 'streams': jsonDecode(text),
              'sha256': null, // No full-file download during remote inventory.
            };
            results.add(result);
            if (exit == 0 && clipDirectory.isNotEmpty) {
              expect(ffmpeg, isNotEmpty);
              final extension = p.extension(source['asset_name'] as String);
              expect(['.mkv', '.mp4'], contains(extension.toLowerCase()));
              final clip = File(
                p.join(clipDirectory, '${results.length}$extension'),
              );
              expect(await clip.exists(), isFalse);
              await clip.parent.create(recursive: true);
              // A bounded stream-copy excerpt retains all audio, subtitles and
              // attachments. Never transcode or fetch the complete remote work.
              process = await Process.start(ffmpeg, [
                '-nostdin',
                '-v',
                'error',
                '-n',
                '-rw_timeout',
                '15000000',
                '-ss',
                '60',
                '-i',
                'http://127.0.0.1:${server.port}/probe',
                '-t',
                '45',
                '-map',
                '0',
                '-c',
                'copy',
                '-fs',
                '536870912',
                clip.path,
              ]);
              final copyOutput = process.stdout.drain<void>();
              final copyErrors = process.stderr.drain<void>();
              final copyExit = await process.exitCode.timeout(
                const Duration(minutes: 2),
              );
              await Future.wait([copyOutput, copyErrors]);
              result['clip_exit_code'] = copyExit;
              result['clip'] = clip.path;
              result['clip_bytes'] = await clip.exists()
                  ? await clip.length()
                  : 0;
              if (copyExit != 0) result['status'] = 'clip_failed';
            }
          } catch (error) {
            results.add({
              'title': title,
              'status': 'failed',
              'error': error.runtimeType.toString(),
            });
          } finally {
            process?.kill();
            relay?.close();
            await server?.close(force: true);
          }
          await reportFile.parent.create(recursive: true);
          await reportFile.writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'scope': clipDirectory.isEmpty
                  ? 'Remote stream metadata only; no playback acceptance or full-file hash'
                  : 'Remote metadata and bounded 45-second stream-copy excerpts; no full-file hash',
              'results': results,
            }),
          );
        }
        expect(results.where((r) => r['status'] != 'probed'), isEmpty);
      } finally {
        await db.close();
      }
    },
    skip: !Platform.isWindows || ffprobe.isEmpty || output.isEmpty,
    timeout: const Timeout(Duration(minutes: 16)),
  );
}
