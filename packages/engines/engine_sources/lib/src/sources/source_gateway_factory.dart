import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import 'local_source_gateway.dart';
import 'smb_source_gateway.dart';
import 'source_credential_store.dart';
import 'webdav_source_gateway.dart';

/// 根据媒体源协议类型构建对应的只读网关实例。
class MediaSourceGatewayFactory implements MediaSourceGatewayFactoryPort {
  /// 创建网关工厂。
  MediaSourceGatewayFactory({
    SourceCredentialStore? credentialStore,
    SecureStoragePort? secureStorage,
    this.webDavPool,
  }) : _credentialStore =
           credentialStore ??
           SourceCredentialStore(
             storage: secureStorage ?? InMemorySecureStorage(),
           );

  final SourceCredentialStore _credentialStore;

  /// 可选跨网关共享的 WebDAV 连接池。
  final WebDavConnectionPool? webDavPool;

  /// 为指定 [source] 创建并初始化对应的 [MediaSourceGateway]。
  ///
  /// 当提供非空 [passwordOverride] 或设 [clearPassword] 为 `true` 时，优先覆盖已保存密码，
  /// 方便在配置编辑弹窗内实时测试连通性。
  @override
  Future<MediaSourceGateway> create(
    MediaSourceView source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async {
    if (source.kind == MediaSourceKind.local) {
      return LocalSourceGateway(rootPath: source.location);
    }

    final effectivePassword = clearPassword
        ? null
        : (passwordOverride != null && passwordOverride.isNotEmpty
              ? passwordOverride
              : await _credentialStore.readPassword(source.id.value));

    switch (source.kind) {
      case MediaSourceKind.local:
        return LocalSourceGateway(rootPath: source.location);
      case MediaSourceKind.webdav:
        final usePool = passwordOverride == null && !clearPassword;
        return WebDavSourceGateway(
          rootUri: Uri.parse(source.location),
          username: source.username,
          password: effectivePassword,
          connectionPool: usePool ? webDavPool : null,
        );
      case MediaSourceKind.smb:
        return SmbSourceGateway(
          rootUri: Uri.parse(source.location),
          username: source.username ?? '',
          password: effectivePassword ?? '',
        );
    }
  }
}
