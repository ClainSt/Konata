import 'package:konata_contracts/konata_contracts.dart';
import 'package:test/test.dart';

void main() {
  group('KonataMediaExtensions 权威扩展名表', () {
    test('准确判定视频、音频、字幕与扫图类型并推导标准 MIME', () {
      expect(KonataMediaExtensions.isVideoFile('ep01.MKV'), isTrue);
      expect(KonataMediaExtensions.isPlayableAudioFile('track01.flac'), isTrue);
      expect(KonataMediaExtensions.isCueSheetFile('album.cue'), isTrue);
      expect(KonataMediaExtensions.isScannableAudioFile('album.cue'), isTrue);
      expect(KonataMediaExtensions.isPlayableAudioFile('album.cue'), isFalse);
      expect(KonataMediaExtensions.isTextSubtitleFile('ep01.sc.ass'), isTrue);
      expect(KonataMediaExtensions.isSubtitleFile('ep01.sup'), isTrue);
      expect(KonataMediaExtensions.isTextSubtitleFile('ep01.sup'), isFalse);
      expect(KonataMediaExtensions.isScanImageFile('booklet_01.webp'), isTrue);
      expect(KonataMediaExtensions.mimeTypeFor('ep01.mkv'), 'video/x-matroska');
      expect(KonataMediaExtensions.mimeTypeFor('track.flac'), 'audio/flac');
    });
  });

  group('KonataNetworkConfig 与 NetworkErrorSanitizer', () {
    test('自动区分 TMDB v3/v4 凭证并规范化备用镜像地址', () {
      const empty = KonataNetworkConfig();
      expect(empty.credentialKind, TmdbCredentialKind.none);

      const v3 = KonataNetworkConfig(
        credential: 'abc123456',
        tmdbBackupApiBase: 'https://mirror.example/3///',
      );
      expect(v3.credentialKind, TmdbCredentialKind.v3ApiKey);
      expect(v3.normalizedTmdbBackupApiBase, 'https://mirror.example/3');

      const v4 = KonataNetworkConfig(credential: 'eyJhbGciOiJIUzI1NiJ9.test');
      expect(v4.credentialKind, TmdbCredentialKind.v4BearerToken);
    });

    test('敏感凭据脱敏与中文错误转译生效', () {
      final redacted = NetworkErrorSanitizer.redactSecrets(
        'https://user:secretPass@nas.local/a?api_key=k999 Authorization: Bearer tok123',
      );
      expect(redacted, isNot(contains('secretPass')));
      expect(redacted, isNot(contains('k999')));
      expect(redacted, isNot(contains('tok123')));

      final msg = NetworkErrorSanitizer.toUserMessage(
        'SocketException: Failed host lookup: \'api.themoviedb.org\'',
        prefix: '检索失败',
      );
      expect(msg, contains('域名解析失败'));
      expect(msg, contains('api.themoviedb.org'));
    });
  });

  group('RemoteEntry 验证器与响应快照', () {
    test('优先使用强 ETag 作为缓存验证器并支持响应文本构建', () {
      final withEtag = RemoteEntry(
        name: 'ep01.ass',
        relativePath: 'ep01.ass',
        isDirectory: false,
        etag: '"abc123"',
        modifiedAt: DateTime.utc(2026, 1, 1),
      );
      expect(withEtag.cacheValidator, '"abc123"');

      final withMtime = RemoteEntry(
        name: 'ep02.ass',
        relativePath: 'ep02.ass',
        isDirectory: false,
        modifiedAt: DateTime.utc(2026, 1, 2),
      );
      expect(withMtime.cacheValidator, startsWith('mtime:'));

      final resp = KonataHttpResponse.text('{"ok":true}', statusCode: 201);
      expect(resp.statusCode, 201);
      expect(resp.body, '{"ok":true}');
    });
  });
}
