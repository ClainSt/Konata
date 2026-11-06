import 'dart:async';
import 'dart:io';

import 'package:ccplayer/core/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smb_connect/smb_connect.dart';

void main() {
  test(
    'WebDAV directory failures retain status even with a non-UTF8 error body',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        await request.drain<void>();
        requests++;
        final status = int.parse(request.uri.pathSegments.first);
        request.response.statusCode = status;
        if (status == 401) {
          request.response.headers.set(
            'WWW-Authenticate',
            'Basic realm="test"',
          );
        }
        request.response.add([0xff]);
        await request.response.close();
      });
      for (final result in {
        401: SourceAccessProblem.authentication,
        403: SourceAccessProblem.permission,
        404: SourceAccessProblem.path,
      }.entries) {
        final dav = WebDav({
          'location': 'http://127.0.0.1:${server.port}/${result.key}/',
          'username': 'test',
          'password': 'incorrect',
        });
        await expectLater(dav.list(dav.root), throwsA(result.value));
      }
      expect(requests, lessThanOrEqualTo(5));
    },
  );

  test('classifies errors returned by SMB and local directory listings', () {
    expect(
      SourceAccessProblem.from(SmbAuthException('')),
      SourceAccessProblem.authentication,
    );
    expect(
      SourceAccessProblem.from(
        SmbException.getMessageByCode(NtStatus.NT_STATUS_BAD_NETWORK_NAME),
      ),
      SourceAccessProblem.path,
    );
    expect(
      SourceAccessProblem.from(const PathAccessException('folder', OSError('Access denied', 5))),
      SourceAccessProblem.permission,
    );
    expect(
      SourceAccessProblem.from(const SocketException('')),
      SourceAccessProblem.network,
    );
    expect(
      SourceAccessProblem.from(TimeoutException('')),
      SourceAccessProblem.timeout,
    );
  });
}
