import '../../domain/models/media_source.dart';
import '../../domain/repositories/file_system_gateway.dart';
import 'local_source_gateway.dart';
import 'smb_source_gateway.dart';
import 'source_credential_store.dart';
import 'webdav_source_gateway.dart';

/// 根据媒体源协议类型构建对应的只读网关实例。
class MediaSourceGatewayFactory {
  /// 创建网关工厂。
  const MediaSourceGatewayFactory({
    SourceCredentialStore? credentialStore,
    this.webDavPool,
  }) : _credentialStore = credentialStore ?? const SourceCredentialStore();

  final SourceCredentialStore _credentialStore;
  final WebDavConnectionPool? webDavPool;

  /// 为指定 [source] 创建并初始化对应的 [MediaSourceGateway]。
  ///
  /// 当提供非空 [passwordOverride] 或设 [clearPassword] 为 `true` 时，优先覆盖已保存密码，
  /// 方便在配置编辑弹窗内实时「测试连通」。
  Future<MediaSourceGateway> create(
    MediaSource source, {
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
              : await _credentialStore.readPassword(source.id));

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
