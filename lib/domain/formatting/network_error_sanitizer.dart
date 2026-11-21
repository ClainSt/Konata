/// 网络异常密钥脱敏与简体中文错误文案转译工具。
///
/// 统一清洗日志、异常堆栈及界面报错中的 `api_key` / `Bearer` 敏感凭据，
/// 并将底层套接字、域名解析、握手与超时异常转换为面向用户的中文提示。
abstract final class NetworkErrorSanitizer {
  static final RegExp _apiKeyQueryPattern = RegExp(
    r'((?:api_key|client_key|api-key|client-key)\s*[=:]\s*)([^&\s)\x27",;]+)',
    caseSensitive: false,
  );
  static final RegExp _encodedApiKeyPattern = RegExp(
    r'((?:api_key|client_key)%3d)([^&\s)\x27",;%]+)',
    caseSensitive: false,
  );
  static final RegExp _bearerTokenPattern = RegExp(
    r'(Bearer\s+)([A-Za-z0-9\-._~+/]+=*)',
    caseSensitive: false,
  );
  static final RegExp _hostLookupPattern = RegExp(
    r"Failed host lookup:\s*'([^']+)'",
    caseSensitive: false,
  );

  /// 将文本中所有明文或编码态 `api_key` 与 `Bearer` 令牌替换为脱敏占位符。
  static String redactSecrets(String input) {
    if (input.isEmpty) return input;
    return input
        .replaceAllMapped(_apiKeyQueryPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_encodedApiKeyPattern, (m) => '${m[1]}***')
        .replaceAllMapped(_bearerTokenPattern, (m) => '${m[1]}***');
  }

  /// 判断异常是否属于可降级容错的外部网络瞬态异常（DNS 失败、连接超时、TLS 握手或连接中断）。
  static bool isTransientNetworkError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('http 401') ||
        text.contains('http 403') ||
        text.contains('密钥无效')) {
      return false;
    }
    return text.contains('failed host lookup') ||
        text.contains('no address associated with hostname') ||
        text.contains('socketexception') ||
        text.contains('timeoutexception') ||
        text.contains('timed out') ||
        text.contains('handshakeexception') ||
        text.contains('tlsexception') ||
        text.contains('certificate_verify_failed') ||
        text.contains('connection closed') ||
        text.contains('connection refused') ||
        text.contains('connection reset') ||
        text.contains('network is unreachable') ||
        text.contains('software caused connection abort') ||
        text.contains('clientexception');
  }

  /// 将底层网络或业务异常脱敏并转译为清晰的简体中文提示。
  static String toUserMessage(Object error, {String? prefix}) {
    final raw = redactSecrets(error.toString()).trim();
    final lower = raw.toLowerCase();
    final head = (prefix != null && prefix.trim().isNotEmpty)
        ? '${prefix.trim()}：'
        : '';

    if (lower.contains('failed host lookup') ||
        lower.contains('no address associated with hostname')) {
      final hostMatch = _hostLookupPattern.firstMatch(raw);
      final host = hostMatch?.group(1)?.trim() ?? '';
      final hostLabel = host.isNotEmpty ? '（$host）' : '';
      return '$head域名解析失败$hostLabel，请检查网络连接、系统代理或备用镜像配置';
    }
    if (lower.contains('timeoutexception') || lower.contains('timed out')) {
      return '$head服务器连接超时，请检查网络环境或代理设置后重试';
    }
    if (lower.contains('handshakeexception') ||
        lower.contains('tlsexception') ||
        lower.contains('certificate_verify_failed')) {
      return '$head安全连接握手异常，请检查网络代理或证书环境';
    }
    if (lower.contains('connection refused')) {
      return '$head目标服务器拒绝连接，请检查服务地址或代理端口';
    }
    if (lower.contains('connection reset') ||
        lower.contains('connection closed') ||
        lower.contains('software caused connection abort')) {
      return '$head网络连接意外中断，请稍后重试';
    }
    if (lower.contains('network is unreachable') ||
        lower.contains('socketexception')) {
      return '$head网络不可达，请检查当前设备网络或代理连接';
    }

    final cleaned = raw
        .replaceFirst(RegExp(r'^(StateError|Exception|FormatException):\s*'), '')
        .replaceFirst(RegExp(r'^Bad state:\s*'), '')
        .trim();
    if (cleaned.isEmpty) {
      return '$head请求发生未知异常';
    }
    if (head.isNotEmpty && !cleaned.startsWith(prefix!.trim())) {
      return '$head$cleaned';
    }
    return cleaned;
  }
}
