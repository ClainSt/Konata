import 'package:flutter/widgets.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

/// 只处理用户主动授权步骤，凭据由宿主安全存储。
Future<String?> showCloudAccountSignInDialog(
  BuildContext context,
  CloudAccountSignInPort session,
) async {
  try {
    return await showKonataGlassDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CloudAccountSignInDialog(session: session),
    );
  } finally {
    session.cancel();
  }
}

class _CloudAccountSignInDialog extends StatefulWidget {
  const _CloudAccountSignInDialog({required this.session});
  final CloudAccountSignInPort session;

  @override
  State<_CloudAccountSignInDialog> createState() =>
      _CloudAccountSignInDialogState();
}

class _CloudAccountSignInDialogState extends State<_CloudAccountSignInDialog> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _sent = false;
  bool _failed = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  // 只展示固定分类文案，不展示服务端原始响应、手机号、令牌或异常正文。
  String _failureMessage(Object error, bool sent) {
    final stage = sent ? '确认授权' : '发送验证码';
    final detail = switch (error) {
      RiskControlled() => '服务端要求额外验证或触发风控，请通过官方授权入口处理。',
      SourceRateLimitException() => '服务端限制请求频率，请遵循服务方的冷却要求。',
      SourceAccessException(kind: SourceAccessProblemKind.permission) =>
        '客户端权限或认证入口被拒绝，请核对获准使用的客户端配置。',
      SourceAccessException(kind: SourceAccessProblemKind.network) =>
        '网络连接或授权服务异常，请检查网络及代理设置。',
      SourceAccessException(kind: SourceAccessProblemKind.timeout) => '授权请求超时。',
      SourceAccessException(kind: SourceAccessProblemKind.tls) => '安全连接校验失败。',
      SourceAccessException(kind: SourceAccessProblemKind.unknown) =>
        '授权接口或响应格式不兼容，需确认服务方支持的接口。',
      SourceAccessException(kind: SourceAccessProblemKind.authentication) =>
        '服务端未接受授权请求或未返回必要的验证会话。',
      _ => '授权发生未知错误，请检查客户端配置。',
    };
    final diagnostic = error is SourceAccessException ? error.cause : null;
    final status = switch (error) {
      SourceRateLimitException(:final statusCode) => statusCode,
      _ =>
        diagnostic is CloudAuthorizationDiagnostic
            ? diagnostic.httpStatus
            : null,
    };
    final code = diagnostic is CloudAuthorizationDiagnostic
        ? diagnostic.serviceCode
        : null;
    final statusText = status != null && status >= 100 && status <= 599
        ? ' HTTP $status'
        : '';
    final codeText = code != null && code >= 0 && code <= 999999
        ? ' 服务端代码 $code'
        : '';
    return '$stage失败：$detail$statusText$codeText';
  }

  Future<void> _submit() async {
    if (_busy || _failed) return;
    final sent = _sent;
    final input = (sent ? _code.text : _phone.text).trim();
    if (!(sent ? RegExp(r'^\d{4,8}$') : RegExp(r'^\+[1-9]\d{6,14}$')).hasMatch(
      input,
    )) {
      setState(() => _error = sent ? '请输入有效短信验证码' : '请输入包含国际区号的手机号');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (sent) {
        final location = await widget.session.finishSms(input);
        if (mounted) Navigator.of(context).pop(location);
      } else {
        await widget.session.sendSms(input);
        if (mounted) setState(() => _sent = true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failed = true;
          _error = _failureMessage(error, sent);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: KonataGlassDialog(
        title: '光鸭账号授权',
        width: 420,
        onClose: _busy ? () {} : () => Navigator.of(context).pop(),
        actions: [
          KonataPillButton.ghost(
            label: '取消',
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          KonataPillButton.primary(
            label: _busy ? '处理中…' : (_sent ? '确认授权' : '发送验证码'),
            onPressed: _busy || _failed ? null : _submit,
          ),
        ],
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('仅用于本机账号授权。手机号、验证码及令牌不会进入媒体库同步。'),
              const SizedBox(height: 12),
              IgnorePointer(
                ignoring: _sent || _busy || _failed,
                child: KonataSoftTextField(
                  controller: _phone,
                  label: '手机号（含国际区号）',
                  hintText: '+86…',
                  keyboardType: TextInputType.phone,
                ),
              ),
              if (_sent) ...[
                const SizedBox(height: 12),
                IgnorePointer(
                  ignoring: _busy || _failed,
                  child: KonataSoftTextField(
                    controller: _code,
                    label: '短信验证码',
                    obscureText: true,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
