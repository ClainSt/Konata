import 'package:flutter/widgets.dart';
import 'app_localizations.dart';

/// Fallback supports standalone widgets hosted without the app's delegates.
/// Production language selection is owned by MaterialApp.
extension LocalizedContext on BuildContext {
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      lookupAppLocalizations(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      );
}

/// Additional localized labels for catalog removal separation and in-place
/// scan review actions without regenerating ARB files across branches.
extension CatalogReviewStrings on BuildContext {
  bool get _isEnglish =>
      (Localizations.maybeLocaleOf(this)?.languageCode ?? 'zh') != 'zh';

  bool get _isTraditionalChinese {
    final locale = Localizations.maybeLocaleOf(this);
    if (locale == null || locale.languageCode != 'zh') return false;
    return locale.scriptCode == 'Hant' ||
        locale.countryCode == 'TW' ||
        locale.countryCode == 'HK' ||
        locale.countryCode == 'MO';
  }

  String _pickLocale({
    required String hans,
    required String hant,
    required String en,
  }) {
    if (_isEnglish) return en;
    if (_isTraditionalChinese) return hant;
    return hans;
  }

  String get confirmAdoptAction => _pickLocale(
    hans: '确认采用',
    hant: '確認採用',
    en: 'Adopt',
  );

  String get rematchAction => _pickLocale(
    hans: '重新匹配',
    hant: '重新匹配',
    en: 'Rematch',
  );

  String get viewDetailsTooltip => _pickLocale(
    hans: '查看详情',
    hant: '查看詳情',
    en: 'View details',
  );

  String get workManageRemovalTitle => _pickLocale(
    hans: '隐藏或删除作品',
    hant: '隱藏或刪除作品',
    en: 'Hide or delete title',
  );

  String get hideWorkAction => _pickLocale(
    hans: '隐藏该作品',
    hant: '隱藏此作品',
    en: 'Hide title',
  );

  String get hideWorkDescription => _pickLocale(
    hans: '仅从海报墙隐藏，保留媒体库记录、人工关联与观看进度，可随时在“管理已隐藏作品”中恢复。',
    hant: '僅從海報牆隱藏，保留媒體庫記錄、人工關聯與觀看進度，可隨時在「管理已隱藏作品」中恢復。',
    en: 'Hide from the poster wall only. Library records, manual matches and progress remain and can be restored anytime.',
  );

  String get deleteWorkAction => _pickLocale(
    hans: '删除该作品',
    hant: '刪除此作品',
    en: 'Delete title',
  );

  String get deleteWorkDescription => _pickLocale(
    hans: '将从媒体库移除该作品记录，不会删除源文件夹中的视频文件。',
    hant: '將從媒體庫移除此作品記錄，不會刪除來源資料夾中的影片檔案。',
    en: 'Removes this title record from the library without deleting video files in the source folder.',
  );

  String get deleteWorkConfirmTitle => _pickLocale(
    hans: '确认删除该作品？',
    hant: '確認刪除此作品？',
    en: 'Delete title from library?',
  );

  String get deleteWorkConfirmBody => _pickLocale(
    hans: '将从媒体库移除该作品记录（含关联剧集、手动修正与观看进度）及专属封面缓存，不会删除源文件夹中的视频文件。',
    hant: '將從媒體庫移除此作品記錄（含關聯劇集、手動修正與觀看進度）及專屬封面快取，不會刪除來源資料夾中的影片檔案。',
    en: 'This removes the title record (including episodes, manual overrides and progress) and its exclusive cover cache from the library. Video files in the source folder will not be deleted.',
  );

  String get confirmDeleteAction => _pickLocale(
    hans: '确认删除',
    hant: '確認刪除',
    en: 'Delete',
  );

  String get reviewActionFailed => _pickLocale(
    hans: '操作失败，请重试',
    hant: '操作失敗，請重試',
    en: 'Action failed, please try again',
  );
}
