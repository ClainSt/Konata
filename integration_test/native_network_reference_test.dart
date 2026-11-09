import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'independent mpv over the same network relay',
    (tester) async {
      expect(Platform.isWindows, isTrue);
      const tag = String.fromEnvironment('NETWORK_TAG');
      final root = await Directory.systemTemp.createTemp('konata-network-');
      final config = File('${root.path}/network-qa.json');
      debugPrint('NETWORK_CONFIG_READY ${config.path}');
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (!await config.exists()) {
        expect(DateTime.now().isBefore(deadline), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final cases = jsonDecode(await config.readAsString()) as List;
      await config.delete();
      final catalog = Catalog.instance;
      await catalog.initialize(dataDirectory: root);
      final reports = <Object?>[];
      try {
        for (final raw in cases) {
          final c = Map<String, Object?>.from(raw as Map);
          final id = await catalog.addSource(
            c['kind'] as String,
            'reference',
            c['location'] as String,
            username: c['username'] as String,
            password: c['password'] as String,
          );
          final source = (await catalog.db.query(
            'sources',
            where: 'id=?',
            whereArgs: [id],
          )).single;
          final ticket = await StreamBroker.instance.issue(
            source,
            c['relative'] as String,
          );
          final output = File('${root.path}/reference.json');
          final script = File('${root.path}/reference.lua');
          final outputPath = jsonEncode(output.path.replaceAll('\\', '/'));
          await script.writeAsString('''
local utils = require('mp.utils')
local rows = {}
local loaded = nil
local seeked = false
mp.register_event('file-loaded', function() loaded = mp.get_time() end)
local function finish()
 local f = assert(io.open($outputPath, 'w'))
 f:write(utils.format_json({version=mp.get_property('mpv-version'), ffmpeg=mp.get_property('ffmpeg-version'), samples=rows}))
 f:close()
 mp.commandv('quit')
end
mp.add_timeout(35, finish)
mp.add_periodic_timer(0.2, function()
 if not loaded then return end
 local elapsed = mp.get_time() - loaded
 local row = {elapsed=elapsed}
 for _, k in ipairs({'time-pos','frame-drop-count','decoder-frame-drop-count','paused-for-cache','avsync','hwdec-current','current-vo'}) do row[k]=mp.get_property_native(k) end
 table.insert(rows,row)
 if elapsed > 5 and not seeked then seeked=true; mp.commandv('seek','40','absolute+exact') end
 if elapsed > 14 then finish() end
end)
''');
          Process? process;
          try {
            process = await Process.start(
              '${Directory.current.path}/.dart_tool/konata-native/windows/reference/mpv.exe',
              [
                ticket.toString(),
                '--no-config',
                '--vo=gpu',
                '--gpu-api=d3d11',
                '--gpu-context=d3d11',
                '--d3d11-output-format=rgb10_a2',
                '--hwdec=auto',
                '--volume=0',
                '--sid=no',
                '--geometry=960x540',
                '--no-terminal',
                '--msg-level=all=error',
                '--script=${script.path}',
              ],
            );
            final streams = Future.wait([
              process.stdout.drain<void>(),
              process.stderr.drain<void>(),
            ]);
            expect(
              await process.exitCode.timeout(const Duration(seconds: 45)),
              0,
            );
            await streams;
            final result =
                jsonDecode(await output.readAsString()) as Map<String, dynamic>;
            result['kind'] = c['kind'];
            result['scope'] =
                'Independent mpv rendering/decoding through the same Konata SMB/WebDAV relay; not an independent SMB client';
            reports.add(result);
            expect(result['version'], 'mpv v0.42.0');
            expect(result['ffmpeg'], '9.0.2');
            final samples = result['samples'] as List;
            expect(
              samples.any((r) => (r['time-pos'] as num? ?? 0) > 47),
              isTrue,
            );
            expect(samples.last['current-vo'], 'gpu');
            await output.delete();
          } finally {
            process?.kill();
            StreamBroker.instance.revoke(ticket);
            await catalog.removeSource(id);
          }
        }
      } finally {
        await File(
          'docs/verification/native-output-20261108/$tag.json',
        ).writeAsString(jsonEncode(reports));
        await catalog.db.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
