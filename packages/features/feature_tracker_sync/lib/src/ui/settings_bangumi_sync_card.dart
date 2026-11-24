import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_design_system/konata_design_system.dart';

import '../data/bangumi_sync_models.dart';
import '../providers.dart';
import '../state/tracker_sync_coordinator.dart';

/// Bangumi 番组计划追番同步设置卡片（纯设计系统组件实现）。
///
/// 支持输入与验证个人访问令牌（PAT）、切换自动同步与同步模式、
/// 展示鉴权失效重绑提示，并支持待重试队列查看与一键补推。
class SettingsBangumiSyncCard extends ConsumerStatefulWidget {
  /// 创建 Bangumi 同步设置卡片。
  const SettingsBangumiSyncCard({
    super.key,
    this.coordinator,
    this.urlOpener,
  });

  /// 可选直传协调器实例；为空时从 [trackerSyncCoordinatorProvider] 获取。
  final TrackerSyncCoordinator? coordinator;

  /// 可选外链打开端口；为空时从 [featureTrackerSyncDependenciesProvider] 获取。
  final UrlOpenerPort? urlOpener;

  @override
  ConsumerState<SettingsBangumiSyncCard> createState() =>
      _SettingsBangumiSyncCardState();
}

class _SettingsBangumiSyncCardState
    extends ConsumerState<SettingsBangumiSyncCard> {
  static final Uri _bangumiTokenPageUri = Uri.parse(
    'https://next.bgm.tv/demo/access-token',
  );

  final TextEditingController _patController = TextEditingController();
  bool _obscureToken = true;
  bool _isWorking = false;
  String? _inlineFeedback;
  bool _inlineIsError = false;

  TrackerSyncCoordinator get _coordinator =>
      widget.coordinator ?? ref.read(trackerSyncCoordinatorProvider);

  UrlOpenerPort get _urlOpener =>
      widget.urlOpener ?? ref.read(featureTrackerSyncDependenciesProvider).urlOpener;

  @override
  void dispose() {
    _patController.dispose();
    super.dispose();
  }

  Future<void> _onVerifyAndSave() async {
    final pat = _patController.text.trim();
    if (pat.isEmpty) {
      setState(() {
        _inlineFeedback = '请先粘贴 Bangumi Access Token（PAT）';
        _inlineIsError = true;
      });
      return;
    }

    setState(() {
      _isWorking = true;
      _inlineFeedback = null;
      _inlineIsError = false;
    });
    try {
      final profile = await _coordinator.bindAndVerifyToken(pat);
      _patController.clear();
      if (!mounted) {
        return;
      }
      setState(() {
        _inlineFeedback = '已验证并绑定：${profile.nickname} (@${profile.username})';
        _inlineIsError = false;
      });
      showKonataToast(
        context,
        '已绑定 Bangumi 账号 ${profile.nickname}',
      );
    } on BangumiAuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _inlineFeedback = error.message;
        _inlineIsError = true;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _inlineFeedback = '验证失败：$error';
        _inlineIsError = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isWorking = false;
        });
      }
    }
  }

  Future<void> _onUnbind() async {
    setState(() {
      _isWorking = true;
      _inlineFeedback = null;
    });
    try {
      await _coordinator.unbindToken();
      _patController.clear();
      if (!mounted) {
        return;
      }
      setState(() {
        _inlineFeedback = '已移除本地保存的 Bangumi PAT';
        _inlineIsError = false;
      });
      showKonataToast(context, '已解绑 Bangumi PAT');
    } finally {
      if (mounted) {
        setState(() {
          _isWorking = false;
        });
      }
    }
  }

  Future<void> _onFlushQueue() async {
    setState(() {
      _isWorking = true;
      _inlineFeedback = null;
      _inlineIsError = false;
    });
    try {
      final flushed = await _coordinator.flushDueQueue(
        includeBackoffScheduled: true,
      );
      if (!mounted) {
        return;
      }
      if (_coordinator.authInvalid) {
        setState(() {
          _inlineFeedback =
              _coordinator.authErrorMessage ?? 'Bangumi PAT 已失效，请重新绑定';
          _inlineIsError = true;
        });
      } else {
        setState(() {
          _inlineFeedback = flushed > 0
              ? '补推成功，共发送 $flushed 条进度'
              : '当前没有可发送的待重试条目';
          _inlineIsError = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isWorking = false;
        });
      }
    }
  }

  Future<void> _onSyncAll() async {
    setState(() {
      _isWorking = true;
      _inlineFeedback = null;
      _inlineIsError = false;
    });
    try {
      final report = await _coordinator.syncAllLibraryWorks(
        ignoreManualGuard: true,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _inlineFeedback = report.authInvalid
            ? (report.errorMessages.firstOrNull ?? 'Bangumi PAT 已失效，请重新绑定')
            : '全库同步完成：同步 ${report.syncedWorks} 部，推送 ${report.pushedEpisodes} 集，回写 ${report.pulledEpisodes} 集';
        _inlineIsError = report.authInvalid || report.failedWorks > 0;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isWorking = false;
        });
      }
    }
  }

  Future<void> _openTokenHelpPage() async {
    final opened = await _urlOpener.openExternalUrl(_bangumiTokenPageUri);
    if (!opened && mounted) {
      showKonataToast(
        context,
        '无法打开外部浏览器，请手动访问 next.bgm.tv/demo/access-token',
        isError: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = _coordinator;
    final tokens = Theme.of(context).extension<KonataPalette>()!;

    return AnimatedBuilder(
      animation: coordinator,
      builder: (context, _) {
        final cfg = coordinator.config;
        final isBusy = _isWorking || coordinator.isBusy;
        final pendingTotal = coordinator.pendingCount;
        final pausedCount = coordinator.pausedPendingCount;

        return KonataSurfaceCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HeaderRow(
                hasToken: coordinator.hasToken,
                authInvalid: coordinator.authInvalid,
                pendingTotal: pendingTotal,
                tokens: tokens,
              ),
              const SizedBox(height: 12),
              if (coordinator.authInvalid) ...[
                _BannerBox(
                  message:
                      coordinator.authErrorMessage ??
                      'Bangumi PAT 鉴权已失效（401/403），已暂停自动推送。请重新生成并绑定有效 PAT。',
                  accentColor: tokens.danger,
                  tokens: tokens,
                ),
                const SizedBox(height: 12),
              ],
              if (cfg.verifiedProfile != null && coordinator.hasToken) ...[
                _ProfileBanner(
                  profile: cfg.verifiedProfile!,
                  lastSyncMs: cfg.lastFullSyncAtMs,
                  tokens: tokens,
                ),
                const SizedBox(height: 14),
              ],
              Row(
                children: [
                  Expanded(
                    child: KonataSoftTextField(
                      controller: _patController,
                      hintText: coordinator.hasToken
                          ? '输入新的 Bangumi PAT 可覆盖更换'
                          : '粘贴 Bangumi 个人访问令牌（PAT）',
                      obscureText: _obscureToken,
                      prefixIcon: Icons.vpn_key_outlined,
                    ),
                  ),
                  const SizedBox(width: 8),
                  KonataPillButton.ghost(
                    label: _obscureToken ? '显示' : '隐藏',
                    compact: true,
                    onPressed: () {
                      setState(() {
                        _obscureToken = !_obscureToken;
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  KonataPillButton.primary(
                    label: isBusy ? '处理中...' : '验证并绑定 PAT',
                    icon: Icons.verified_user_outlined,
                    compact: true,
                    onPressed: isBusy ? null : _onVerifyAndSave,
                  ),
                  KonataPillButton.secondary(
                    label: '获取 PAT',
                    icon: Icons.open_in_new_rounded,
                    compact: true,
                    onPressed: _openTokenHelpPage,
                  ),
                  if (coordinator.hasToken)
                    KonataPillButton.ghost(
                      label: '解绑 PAT',
                      icon: Icons.link_off_rounded,
                      compact: true,
                      onPressed: isBusy ? null : _onUnbind,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: tokens.hairline),
              const SizedBox(height: 14),
              _SwitchRow(
                title: '启用 Bangumi 追番进度同步',
                subtitle: '直连官方 https://api.bgm.tv 同步观影状态',
                value: cfg.enabled,
                tokens: tokens,
                onChanged: (value) {
                  coordinator.updateConfig(cfg.copyWith(enabled: value));
                },
              ),
              const SizedBox(height: 12),
              _SwitchRow(
                title: '单集完播后自动同步',
                subtitle: '完播事件自动进入离线防丢队列并按指数退避推送',
                value: cfg.autoSyncOnEpisodeComplete,
                tokens: tokens,
                onChanged: (value) {
                  coordinator.updateConfig(
                    cfg.copyWith(autoSyncOnEpisodeComplete: value),
                  );
                },
              ),
              const SizedBox(height: 12),
              _SwitchRow(
                title: '全部正片看完后自动标记「看过」',
                subtitle: '全集同步完成时将条目收藏状态提升为看过',
                value: cfg.autoMarkCollectionCompleted,
                tokens: tokens,
                onChanged: (value) {
                  coordinator.updateConfig(
                    cfg.copyWith(autoMarkCollectionCompleted: value),
                  );
                },
              ),
              const SizedBox(height: 16),
              Text(
                '同步策略模式',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tokens.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              KonataSegmentedCapsule<BangumiSyncMode>(
                selected: cfg.syncMode,
                onChanged: (mode) {
                  coordinator.updateConfig(cfg.copyWith(syncMode: mode));
                },
                options: const [
                  KonataSegmentOption(
                    value: BangumiSyncMode.autoCompleteAndPush,
                    label: '双向对齐',
                  ),
                  KonataSegmentOption(
                    value: BangumiSyncMode.pushOnly,
                    label: '仅推送本地',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: tokens.hairline),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '待重试推送队列：$pendingTotal 条',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: tokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          pausedCount > 0
                              ? '其中 $pausedCount 条因鉴权或条目缺失暂停'
                              : '离线完播事件将在恢复联网后自动补推',
                          style: TextStyle(
                            fontSize: 12,
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  KonataPillButton.secondary(
                    label: '一键补推',
                    icon: Icons.send_rounded,
                    compact: true,
                    onPressed: (isBusy || pendingTotal == 0)
                        ? null
                        : _onFlushQueue,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              KonataPillButton.primary(
                label: '立即同步全库 Bangumi 进度',
                icon: Icons.sync_rounded,
                compact: true,
                onPressed: (isBusy || !coordinator.hasToken)
                    ? null
                    : _onSyncAll,
              ),
              if (_inlineFeedback != null && _inlineFeedback!.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _inlineFeedback!,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: _inlineIsError ? tokens.danger : tokens.accent,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.hasToken,
    required this.authInvalid,
    required this.pendingTotal,
    required this.tokens,
  });

  final bool hasToken;
  final bool authInvalid;
  final int pendingTotal;
  final KonataPalette tokens;

  @override
  Widget build(BuildContext context) {
    final String badgeText;
    final Color badgeColor;
    if (authInvalid) {
      badgeText = '鉴权失效需重绑';
      badgeColor = tokens.danger;
    } else if (hasToken) {
      badgeText = pendingTotal > 0 ? '已绑定 · 待推 $pendingTotal' : '已连接官方 API';
      badgeColor = tokens.accent;
    } else {
      badgeText = '未绑定 PAT';
      badgeColor = tokens.textSecondary;
    }

    return Row(
      children: [
        Icon(
          Icons.track_changes_rounded,
          size: 20,
          color: tokens.accent,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Bangumi 番组计划同步',
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              color: tokens.textPrimary,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            badgeText,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: badgeColor,
            ),
          ),
        ),
      ],
    );
  }
}

class _BannerBox extends StatelessWidget {
  const _BannerBox({
    required this.message,
    required this.accentColor,
    required this.tokens,
  });

  final String message;
  final Color accentColor;
  final KonataPalette tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accentColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: accentColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12.5,
                color: tokens.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileBanner extends StatelessWidget {
  const _ProfileBanner({
    required this.profile,
    required this.lastSyncMs,
    required this.tokens,
  });

  final BangumiUserProfile profile;
  final int? lastSyncMs;
  final KonataPalette tokens;

  @override
  Widget build(BuildContext context) {
    final lastText = lastSyncMs == null
        ? '尚未执行全库同步'
        : '上次全库同步：${_formatTimestamp(lastSyncMs!)}';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.softFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.person_outline_rounded, size: 18, color: tokens.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${profile.nickname} (@${profile.username})',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tokens.textPrimary,
                  ),
                ),
                Text(
                  lastText,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: tokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTimestamp(int utcMs) {
    final local = DateTime.fromMillisecondsSinceEpoch(utcMs, isUtc: true).toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$m-$d $hh:$mm';
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.tokens,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final KonataPalette tokens;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: tokens.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: tokens.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        KonataSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}
