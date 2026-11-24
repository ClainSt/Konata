/// Konata v3 统一播放内核、字幕内存引擎与音频安全链唯一公开出口。
///
/// 严禁跨包导入本包内部路径；所有调用方统一导入本文件。
library;

export 'src/application/playback_application.dart';
export 'src/domain/playback_domain.dart';
export 'src/infrastructure/playback_infrastructure.dart';
