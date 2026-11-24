import 'package:material_ui/material_ui.dart';

/// Konata v3 声明式扩展点图标键名映射表（供壳层导航、详情扩展标签与菜单统一解析）。
abstract final class KonataIconRegistry {
  /// 按扩展点声明的 [iconKey] 解析对应的标准界面图标。
  static IconData resolve(String iconKey) {
    return switch (iconKey.trim().toLowerCase()) {
      'library' || 'movies' => Icons.movie_filter_outlined,
      'sources' || 'folder' => Icons.folder_open_rounded,
      'history' || 'clock' => Icons.history_rounded,
      'settings' || 'tune' => Icons.settings_outlined,
      'episodes' || 'video' => Icons.video_library_outlined,
      'extras' || 'special' => Icons.auto_awesome_outlined,
      'cd' || 'music' || 'audio' => Icons.album_outlined,
      'scan_viewer' || 'scans' || 'gallery' => Icons.photo_library_outlined,
      'rescrape' || 'refresh' => Icons.refresh_rounded,
      'edit' => Icons.edit_outlined,
      'artwork' || 'image' => Icons.image_outlined,
      'merge' => Icons.merge_type_rounded,
      'series' || 'collections' => Icons.collections_bookmark_outlined,
      'delete' || 'trash' => Icons.delete_outline_rounded,
      'review' || 'warning' => Icons.fact_check_outlined,
      'search' => Icons.search_rounded,
      'play' => Icons.play_arrow_rounded,
      'sync' => Icons.sync_rounded,
      'info' => Icons.info_outline_rounded,
      _ => Icons.extension_outlined,
    };
  }
}
