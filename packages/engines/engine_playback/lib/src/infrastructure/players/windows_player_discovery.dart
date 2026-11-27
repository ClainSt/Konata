import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/external_player_config.dart';

/// 从 Windows 安装目录和可执行文件搜索路径发现受支持的桌面播放器。
ExternalPlayerConfig? discoverWindowsExternalPlayer(
  Map<String, String> environment,
) {
  final env = {
    for (final entry in environment.entries)
      entry.key.toUpperCase(): entry.value,
  };
  final roots = <String>{
    for (final key in ['PROGRAMW6432', 'PROGRAMFILES', 'PROGRAMFILES(X86)'])
      if (env[key] case final String root when p.windows.isAbsolute(root)) root,
  };
  final pathRoots = <String>[
    for (final raw in (env['PATH'] ?? '').split(';'))
      if (raw.trim().replaceAll('"', '') case final String root
          when p.windows.isAbsolute(root))
        root,
  ];
  final chocolatey = env['CHOCOLATEYINSTALL'];
  final programData = env['PROGRAMDATA'];
  final candidates = <({ExternalPlayerKind kind, String name, String path})>[
    for (final root in roots)
      (
        kind: ExternalPlayerKind.mpv,
        name: 'MPV',
        path: p.windows.join(root, 'mpv', 'mpv.exe'),
      ),
    if (chocolatey != null && p.windows.isAbsolute(chocolatey))
      (
        kind: ExternalPlayerKind.mpv,
        name: 'MPV',
        path: p.windows.join(chocolatey, 'bin', 'mpv.exe'),
      ),
    if (programData != null && p.windows.isAbsolute(programData))
      (
        kind: ExternalPlayerKind.mpv,
        name: 'MPV',
        path: p.windows.join(programData, 'chocolatey', 'bin', 'mpv.exe'),
      ),
    for (final root in pathRoots)
      (
        kind: ExternalPlayerKind.mpv,
        name: 'MPV',
        path: p.windows.join(root, 'mpv.exe'),
      ),
    for (final root in roots)
      for (final executable in ['PotPlayerMini64.exe', 'PotPlayerMini.exe'])
        (
          kind: ExternalPlayerKind.potplayer,
          name: 'PotPlayer',
          path: p.windows.join(root, 'DAUM', 'PotPlayer', executable),
        ),
    for (final root in pathRoots)
      for (final executable in ['PotPlayerMini64.exe', 'PotPlayerMini.exe'])
        (
          kind: ExternalPlayerKind.potplayer,
          name: 'PotPlayer',
          path: p.windows.join(root, executable),
        ),
  ];

  for (final candidate in candidates) {
    if (!File(candidate.path).existsSync()) continue;
    return ExternalPlayerConfig(
      id: 'auto_${candidate.kind.name}',
      name: candidate.name,
      kind: candidate.kind,
      executablePath: candidate.path,
      isDefault: true,
    );
  }
  return null;
}
