import 'dart:async';
import 'dart:convert';

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
}) => LegacyGuangYaProtocol(
  credentials: const GuangYaCredentials(
    clientId: 'fixture-client',
    deviceId: '00000000000000000000000000000000',
    refreshToken: 'refresh-fixture-initial',
    subject: 'fixture-user',
  ),
  request: request,
  persistRefresh: persist ?? (_) async {},
  spacing: Duration.zero,
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
