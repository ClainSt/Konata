import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:engine_cloud_drives/engine_cloud_drives.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

KonataHttpResponse response(Map<String, Object?> value, {int status = 200}) =>
    KonataHttpResponse.text(jsonEncode(value), statusCode: status);

Map<String, Object?> token(String id, {String subject = 'fixture-user'}) => {
  'access_token': 'access-fixture-$id',
  'refresh_token': 'refresh-fixture-$id',
  'expires_in': 3600,
  'sub': subject,
};

Map<String, Object?> row(String id, String name, {int kind = 1}) => {
  'fileId': id,
  'fileName': name,
  'resType': kind,
  'fileSize': 42,
};

KonataHttpResponse page(List<Map<String, Object?>> rows, int total) =>
    response({
      'code': 0,
      'data': {'list': rows, 'total': total},
    });

LegacyGuangYaProtocol protocol(
  GuangYaRequest request, {
  Future<void> Function(String)? persist,
  int maxPages = 10,
  Duration spacing = Duration.zero,
}) => LegacyGuangYaProtocol(
  credentials: const GuangYaCredentials(
    clientId: 'fixture-client',
    deviceId: '00000000000000000000000000000000',
    refreshToken: 'refresh-fixture-initial',
    subject: 'fixture-user',
  ),
  request: request,
  persistRefresh: persist ?? (_) async {},
  spacing: spacing,
  maxPages: maxPages,
);

void main() {
  test('二十并发初次访问仅刷新一次，轮换保存完成后才访问业务', () async {
    var refreshes = 0, calls = 0, saved = false;
    final api = protocol(
      (method, uri, headers, body) async {
        expect(method, 'POST');
        if (uri.host == 'account.guangyapan.com') {
          refreshes++;
          expect(headers['Authorization'], isNull);
          expect(body?['refresh_token'], 'refresh-fixture-initial');
          return response(token('one'));
        }
        calls++;
        expect(saved, isTrue);
        expect(headers['Authorization'], 'Bearer access-fixture-one');
        expect(headers['X-Client-Id'], isNull);
        return page([row('9007199254740999', 'sample.mkv')], 1);
      },
      persist: (value) async {
        expect(value, 'refresh-fixture-one');
        saved = true;
      },
    );
    addTearDown(api.close);
    final lists = await Future.wait(List.generate(20, (_) => api.list('')));
    expect(refreshes, 1);
    expect(calls, 20);
    expect(lists.first.single.id, '9007199254740999');
  });

  test('业务认证失效后只刷新一次并重放，轮换令牌用于下一次刷新', () async {
    var refreshes = 0;
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') {
        refreshes++;
        expect(
          body?['refresh_token'],
          refreshes == 1 ? 'refresh-fixture-initial' : 'refresh-fixture-one',
        );
        return response(token(refreshes == 1 ? 'one' : 'two'));
      }
      if (headers['Authorization'] == 'Bearer access-fixture-one') {
        return response({}, status: 401);
      }
      return page([], 0);
    });
    addTearDown(api.close);
    await api.list('');
    expect(refreshes, 2);
  });

  test('风控阻断已经排队的请求，不继续访问接口', () async {
    var calls = 0;
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      calls++;
      return response({'error': 'captcha_invalid'}, status: 403);
    });
    addTearDown(api.close);
    await Future.wait(
      List.generate(10, (_) async {
        await expectLater(api.list(''), throwsA(isA<RiskControlled>()));
      }),
    );
    expect(calls, 1);
  });

  test('账号主体不一致拒绝访问目录', () async {
    final api = protocol((method, uri, headers, body) async {
      expect(uri.host, 'account.guangyapan.com');
      return response(token('one', subject: 'other'));
    });
    addTearDown(api.close);
    await expectLater(api.list(''), throwsA(isA<SourceAccessException>()));
  });

  test('目录携带空文件类型筛选，兼容无 code 的明确成功响应', () async {
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      expect(body?['fileTypes'], isEmpty);
      expect(body?['parentId'], '');
      return response({
        'msg': 'success',
        'data': {
          'list': [row('9876543210987654321', 'Anime', kind: 2)],
          'total': 1,
        },
      });
    });
    addTearDown(api.close);
    expect((await api.list('')).single.id, '9876543210987654321');
  });

  test('显式业务拒绝不能被成功消息或目录数据覆盖', () async {
    for (final envelope in [
      {'code': 123, 'msg': 'success'},
      {'code': 0, 'error': 'fixture-error'},
      {'msg': 'denied'},
      <String, Object?>{},
    ]) {
      final api = protocol((method, uri, headers, body) async {
        if (uri.host == 'account.guangyapan.com') return response(token('one'));
        return response({
          ...envelope,
          'data': {'list': <Object?>[], 'total': 0},
        });
      });
      try {
        await expectLater(api.list(''), throwsA(isA<SourceAccessException>()));
      } finally {
        await api.close();
      }
    }
  });

  test('两页目录保留字符串文件标识和已知类型', () async {
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      if (body?['page'] == 0) {
        return page(List.generate(100, (i) => row('id-$i', 'file-$i')), 102);
      }
      return page([
        row('dir', 'folder', kind: 2),
        row('unknown', 'unknown', kind: 9),
      ], 102);
    });
    addTearDown(api.close);
    final files = await api.list('root');
    expect(files.length, 101);
    expect(files.last.directory, isTrue);
  });

  test('超过分页上限或重复文件 ID 不返回不完整目录', () async {
    for (final duplicate in [false, true]) {
      final api = protocol((method, uri, headers, body) async {
        if (uri.host == 'account.guangyapan.com') return response(token('one'));
        return page(
          List.generate(
            100,
            (i) => row(duplicate ? 'same' : 'id-$i', 'file-$i'),
          ),
          200,
        );
      }, maxPages: 1);
      try {
        await expectLater(api.list(''), throwsA(isA<SourceAccessException>()));
      } finally {
        await api.close();
      }
    }
  });

  test('取链兼容空主地址和带空白的备用地址，显式拒绝仍失败', () async {
    for (final primary in [null, '', '   ']) {
      final api = protocol((method, uri, headers, body) async {
        if (uri.host == 'account.guangyapan.com') return response(token('one'));
        expect(uri.path, '/nd.bizuserres.s/v1/get_res_download_url');
        expect(body?['fileId'], 'fixture-id');
        return response({
          'msg': 'success',
          'data': {
            'signedURL': primary,
            'downloadUrl': ' https://cdn.example.invalid/file?sig=fixture ',
          },
        });
      });
      try {
        expect(
          (await api.link('fixture-id')).uri,
          Uri.parse('https://cdn.example.invalid/file?sig=fixture'),
        );
      } finally {
        await api.close();
      }
    }
  });

  test('直链必须为 HTTPS，禁止含用户凭据的 URL', () async {
    for (final url in [
      'http://cdn.example.invalid/file',
      'https://user:secret@cdn.example.invalid/file',
      'https://cdn.example.invalid/file?signature=fixture',
    ]) {
      final api = protocol((method, uri, headers, body) async {
        if (uri.host == 'account.guangyapan.com') return response(token('one'));
        expect(body?['fileId'], 'id');
        return response({
          'code': 0,
          'data': {'signedURL': url},
        });
      });
      try {
        if (url.contains('signature=')) {
          expect((await api.link('id')).uri.scheme, 'https');
        } else {
          await expectLater(
            api.link('id'),
            throwsA(isA<SourceAccessException>()),
          );
        }
      } finally {
        await api.close();
      }
    }
  });

  test('网关路径遍历保留文件 ID，拒绝路径逃逸和超限小文件', () async {
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      expect(uri.path, contains('get_file_list'));
      return body?['parentId'] == 'root'
          ? page([row('dir', 'CDs', kind: 2)], 1)
          : page([row('file', 'sample.flac')], 1);
    });
    final gateway = GuangYaGateway(protocol: api, rootId: 'root');
    addTearDown(gateway.close);
    final entries = await gateway.listDirectory('CDs');
    expect(entries.single.relativePath, 'CDs/sample.flac');
    expect(entries.single.remoteFileId, 'file');
    expect(await gateway.probeFileLength('CDs/sample.flac'), 42);
    expect(await gateway.readTextFile('CDs/sample.flac', maxBytes: 10), isNull);
    await expectLater(
      gateway.listDirectory('../'),
      throwsA(isA<SourceAccessException>()),
    );
  });

  test('一万零一条目录保留精确文件标识并限制请求次数', () async {
    var calls = 0;
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      final index = body!['page'] as int;
      expect(index, calls++);
      final count = index == 100 ? 1 : 100;
      return page(
        List.generate(count, (i) {
          final id = 9007199254740993 + index * 100 + i;
          return row('$id', 'file-$id');
        }),
        10001,
      );
    }, maxPages: 101);
    addTearDown(api.close);
    final files = await api.list('root');
    expect(calls, 101);
    expect(files.length, 10001);
    expect(files.map((e) => e.id).toSet().length, 10001);
    expect(files.first.id, '9007199254740993');
    expect(files.last.id, '9007199254750993');
  });

  test('跨页重复、总数变化、条目超量和提前结束均拒绝', () async {
    for (final mode in ['duplicate', 'changed', 'overshoot', 'short']) {
      var calls = 0;
      final api = protocol((method, uri, headers, body) async {
        if (uri.host == 'account.guangyapan.com') return response(token('one'));
        calls++;
        if (body?['page'] == 0) {
          return page(List.generate(100, (i) => row('id-$i', 'file-$i')), 102);
        }
        switch (mode) {
          case 'duplicate':
            return page([
              row('id-0', 'file-0'),
              row('id-101', 'file-101'),
            ], 102);
          case 'changed':
            return page([row('id-100', 'file-100')], 101);
          case 'overshoot':
            return page(List.generate(3, (i) => row('end-$i', 'end-$i')), 102);
          default:
            return page([], 102);
        }
      });
      try {
        await expectLater(
          api.list('root'),
          throwsA(isA<SourceAccessException>()),
        );
        expect(calls, 2);
      } finally {
        await api.close();
      }
    }
  });

  test('宽目录树深度优先减少缓存驱逐后的重复父目录请求', () async {
    const branches = 96;
    Future<({int calls, int elapsedMs, List<String> paths})> sample(
      bool depthFirst,
    ) async {
      var calls = 0;
      final api = protocol((method, uri, headers, body) async {
        if (uri.host == 'account.guangyapan.com') return response(token('one'));
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        final parent = body!['parentId'] as String;
        if (parent == 'root') {
          return page(
            List.generate(branches, (i) => row('dir-$i', 'dir-$i', kind: 2)),
            branches,
          );
        }
        if (parent.startsWith('dir-')) {
          return page([row('sub-$parent', 'Scans', kind: 2)], 1);
        }
        return page([row('file-$parent', '01.jpg')], 1);
      });
      final gateway = GuangYaGateway(
        protocol: api,
        rootId: 'root',
        listingHintTtl: Duration.zero,
      );
      final queue = <String>[''];
      final paths = <String>[];
      final watch = Stopwatch()..start();
      try {
        while (queue.isNotEmpty) {
          final entries = await gateway.listDirectory(queue.removeAt(0));
          for (final entry in entries) {
            if (entry.isDirectory) {
              if (depthFirst) {
                queue.insert(0, entry.relativePath);
              } else {
                queue.add(entry.relativePath);
              }
            } else {
              paths.add(entry.relativePath);
            }
          }
        }
        paths.sort();
        return (
          calls: calls,
          elapsedMs: watch.elapsedMilliseconds,
          paths: paths,
        );
      } finally {
        await gateway.close();
      }
    }

    await sample(false);
    await sample(true);
    final oldTimes = <int>[];
    final newTimes = <int>[];
    for (var i = 0; i < 5; i++) {
      final before = await sample(false);
      final after = await sample(true);
      expect(before.calls, greaterThan(after.calls));
      expect(after.calls, 1 + branches * 2);
      expect(after.paths, before.paths);
      expect(after.paths.length, branches);
      oldTimes.add(before.elapsedMs);
      newTimes.add(after.elapsedMs);
      stdout.writeln(
        '第${i + 1}次：广度 ${before.calls} 次/${before.elapsedMs}ms，深度 ${after.calls} 次/${after.elapsedMs}ms',
      );
    }
    oldTimes.sort();
    newTimes.sort();
    stdout.writeln('中位数：广度 ${oldTimes[2]}ms，深度 ${newTimes[2]}ms');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('目录起搏稳定后缩短且请求失败后恢复原间隔', () async {
    final clock = Stopwatch()..start();
    final starts = <int>[];
    var fail = false;
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      starts.add(clock.elapsedMilliseconds);
      if (fail) {
        throw const SourceAccessException(
          SourceAccessProblemKind.network,
          'fixture',
        );
      }
      return page([], 0);
    }, spacing: const Duration(milliseconds: 550));
    addTearDown(api.close);
    for (var i = 0; i < 11; i++) {
      await api.list('root');
    }
    fail = true;
    await expectLater(api.list('root'), throwsA(isA<SourceAccessException>()));
    fail = false;
    await api.list('root');
    final gaps = [
      for (var i = 1; i < starts.length; i++) starts[i] - starts[i - 1],
    ];
    expect(gaps.take(7), everyElement(greaterThanOrEqualTo(540)));
    expect(gaps.skip(7).take(4), everyElement(greaterThanOrEqualTo(340)));
    expect(gaps.last, greaterThanOrEqualTo(540));
    final warm = gaps.take(7).toList()..sort();
    final stable = gaps.skip(7).take(4).toList()..sort();
    expect(stable[1], lessThan(warm[3]));
    stdout.writeln('稳定目录间隔：${warm[3]}ms → ${stable[1]}ms；故障后 ${gaps.last}ms');
  });

  test('扫描提示避免重复枚举祖先，且目录重名仍拒绝', () async {
    final calls = <String>[];
    var duplicate = false;
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      final id = body!['parentId'] as String;
      calls.add(id);
      if (id == 'root') {
        return page([
          row('dir', 'A', kind: 2),
          if (duplicate) row('other', 'A', kind: 2),
        ], duplicate ? 2 : 1);
      }
      if (id == 'dir') return page([row('sub', 'Scans', kind: 2)], 1);
      return page([row('file', '01.jpg')], 1);
    });
    final gateway = GuangYaGateway(
      protocol: api,
      rootId: 'root',
      directoryCacheTtl: Duration.zero,
    );
    addTearDown(gateway.close);
    await gateway.listDirectory('');
    await gateway.listDirectory('A');
    final entries = await gateway.listDirectory('A/Scans');
    expect(entries.single.remoteFileId, 'file');
    expect(calls, ['root', 'dir', 'sub']);
    duplicate = true;
    await gateway.listDirectory('');
    await expectLater(
      gateway.listDirectory('A'),
      throwsA(isA<SourceAccessException>()),
    );
    expect(calls, ['root', 'dir', 'sub', 'root', 'root']);
  });

  test('五轮冷缓存目录遍历性能及清单等价', () async {
    Future<({int calls, int ms, List<String> files})> sample(bool hints) async {
      var calls = 0;
      final api = protocol((method, uri, headers, body) async {
        if (uri.host == 'account.guangyapan.com') return response(token('one'));
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        final id = body!['parentId'] as String;
        if (id == 'root') {
          return page(
            List.generate(12, (i) => row('dir-$i', 'dir-$i', kind: 2)),
            12,
          );
        }
        if (id.startsWith('dir-')) {
          return page([row('sub-$id', 'Scans', kind: 2)], 1);
        }
        return page([row('file-$id', '01.jpg')], 1);
      });
      final gateway = GuangYaGateway(
        protocol: api,
        rootId: 'root',
        directoryCacheTtl: Duration.zero,
        listingHintTtl: hints ? const Duration(minutes: 2) : Duration.zero,
      );
      final pending = <String>[''];
      final files = <String>[];
      final watch = Stopwatch()..start();
      try {
        while (pending.isNotEmpty) {
          for (final entry in await gateway.listDirectory(
            pending.removeLast(),
          )) {
            if (entry.isDirectory) {
              pending.add(entry.relativePath);
            } else {
              files.add(entry.relativePath);
            }
          }
        }
        files.sort();
        return (calls: calls, ms: watch.elapsedMilliseconds, files: files);
      } finally {
        await gateway.close();
      }
    }

    await sample(false);
    await sample(true);
    final before = <int>[], after = <int>[];
    for (var i = 0; i < 5; i++) {
      final a = await sample(false), b = await sample(true);
      expect(a.calls, 61);
      expect(b.calls, 25);
      expect(a.files, b.files);
      before.add(a.ms);
      after.add(b.ms);
      stdout.writeln(
        '第${i + 1}次：${a.calls}次/${a.ms}ms → ${b.calls}次/${b.ms}ms',
      );
    }
    before.sort();
    after.sort();
    stdout.writeln('中位数：${before[2]}ms → ${after[2]}ms');
  });

  test('目录缓存到期后重查，关闭缓存时并发请求仍合并', () async {
    var calls = 0;
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      calls++;
      return page([row('id-$calls', 'file-$calls')], 1);
    });
    final gateway = GuangYaGateway(
      protocol: api,
      rootId: 'root',
      directoryCacheTtl: Duration.zero,
    );
    addTearDown(gateway.close);
    final batch = await Future.wait(
      List.generate(20, (_) => gateway.listDirectory('')),
    );
    expect(calls, 1);
    expect(
      batch.every((entries) => entries.single.remoteFileId == 'id-1'),
      isTrue,
    );
    expect((await gateway.listDirectory('')).single.remoteFileId, 'id-2');
    expect(calls, 2);
  });

  test('默认目录缓存复用，直链并发获取和换链各只调用一次', () async {
    var listings = 0, links = 0;
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      if (uri.path.contains('get_file_list')) {
        listings++;
        return page([row('media', 'file.mkv')], 1);
      }
      links++;
      return response({
        'code': 0,
        'data': {
          'signedURL': 'https://cdn.example.invalid/media?generation=$links',
        },
      });
    });
    final gateway = GuangYaGateway(protocol: api, rootId: 'root');
    addTearDown(gateway.close);
    final upstream = await gateway.upstreamFor('file.mkv');
    await gateway.listDirectory('');
    expect(listings, 1);
    final first = await Future.wait(
      List.generate(20, (_) => upstream.current()),
    );
    expect(links, 1);
    expect(first.every((link) => link.uri.query == 'generation=1'), isTrue);
    final second = await Future.wait(
      List.generate(20, (_) => upstream.renew()),
    );
    expect(links, 2);
    expect(second.every((link) => link.uri.query == 'generation=2'), isTrue);
    expect((await upstream.current()).uri.query, 'generation=2');
    expect(links, 2);
  });

  test('HTTP 429阻断已排队的目录与取链请求', () async {
    var business = 0;
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      business++;
      return KonataHttpResponse.text('{}', statusCode: 429);
    });
    addTearDown(api.close);
    final limited = isA<SourceRateLimitException>().having(
      (e) => e.retryAfter!.inMilliseconds,
      '冷却时间',
      greaterThan(0),
    );
    await Future.wait([
      for (var i = 0; i < 10; i++)
        expectLater(api.list('root'), throwsA(limited)),
      for (var i = 0; i < 10; i++)
        expectLater(api.link('file'), throwsA(limited)),
    ]);
    expect(business, 1);
    await expectLater(api.list('root'), throwsA(limited));
    expect(business, 1);
  });

  test('传输层限流同样阻断排队请求', () async {
    var calls = 0;
    final api = protocol((method, uri, headers, body) async {
      calls++;
      throw const RateLimitedHttpException(Duration(seconds: 90));
    });
    addTearDown(api.close);
    await Future.wait(
      List.generate(
        20,
        (_) => expectLater(
          api.list('root'),
          throwsA(isA<SourceRateLimitException>()),
        ),
      ),
    );
    expect(calls, 1);
    await expectLater(
      api.link('file'),
      throwsA(
        isA<SourceRateLimitException>().having(
          (e) => e.retryAfter!.inSeconds,
          '剩余冷却',
          greaterThan(80),
        ),
      ),
    );
    expect(calls, 1);
  });

  test('关闭期间已排队的请求不再发送，正在执行的结果不再发布', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    var business = 0;
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      business++;
      entered.complete();
      await release.future;
      return page([], 0);
    });
    final requests = Future.wait(
      List.generate(
        10,
        (_) => expectLater(
          api.list('root'),
          throwsA(isA<SourceAccessException>()),
        ),
      ),
    );
    await entered.future;
    await api.close();
    release.complete();
    await requests;
    expect(business, 1);
  });

  test('关闭时进行中的目录查询不再写入缓存', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final api = protocol((method, uri, headers, body) async {
      if (uri.host == 'account.guangyapan.com') return response(token('one'));
      entered.complete();
      await release.future;
      return page([], 0);
    });
    final gateway = GuangYaGateway(protocol: api, rootId: 'root');
    final pending = expectLater(
      gateway.listDirectory(''),
      throwsA(isA<SourceAccessException>()),
    );
    await entered.future;
    await gateway.close();
    release.complete();
    await pending;
    await expectLater(
      gateway.listDirectory(''),
      throwsA(isA<SourceAccessException>()),
    );
  });
}
