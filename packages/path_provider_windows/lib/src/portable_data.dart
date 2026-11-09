import 'dart:io';
import 'package:path/path.dart' as path;

/// Copies legacy data once, before any database or preferences are opened.
/// The old directory remains intact; an existing portable directory always wins.
Future<Directory> preparePortableData(
    Directory target, Directory? legacy) async {
  if (await FileSystemEntity.type(target.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw FileSystemException(
        'Portable data directory must not be a link', target.path);
  }
  if (!await target.exists()) {
    await target.parent.create(recursive: true);
    if (legacy != null && await legacy.exists()) {
      final stage = await target.parent.createTemp('.konata-import-');
      final locks = <String, RandomAccessFile>{};
      var promoted = false;
      try {
        // SQLite holds locks in these files while another copy is running.
        // Refuse a concurrent migration instead of copying a changing database.
        for (final name in [
          for (final database in ['ccplayer.db', 'artwork/cache-index.sqlite'])
            for (final suffix in ['', '-wal', '-shm', '-journal'])
              '$database$suffix',
        ]) {
          final file = File(path.join(legacy.path, name));
          if (!await file.exists()) continue;
          final handle = await file.open();
          locks[path.normalize(file.path)] = handle;
          // SQLite's database locks live at 0x40000000, beyond the EOF of
          // ordinary libraries. Windows' default EOF range does not cover them.
          await handle.lock(FileLock.exclusive, 0, 0x7fffffff);
        }
        await for (final entry
            in legacy.list(recursive: true, followLinks: false)) {
          final destination = path.join(
              stage.path, path.relative(entry.path, from: legacy.path));
          if (entry is Link) {
            throw FileSystemException(
                'Legacy data contains a link; migration stopped', entry.path);
          } else if (entry is Directory) {
            await Directory(destination).create(recursive: true);
          } else if (entry is File) {
            await File(destination).parent.create(recursive: true);
            final before = await entry.stat();
            final held = locks[path.normalize(entry.path)];
            final copied = File(destination);
            if (held == null) {
              await entry.copy(destination);
            } else {
              // Windows denies CopyFile's second handle while our lock is held.
              // Read through the same locked handle with a bounded buffer.
              final output = await copied.open(mode: FileMode.write);
              try {
                await held.setPosition(0);
                while (true) {
                  final bytes = await held.read(64 * 1024);
                  if (bytes.isEmpty) break;
                  await output.writeFrom(bytes);
                }
                await output.flush();
              } finally {
                await output.close();
              }
            }
            final after = await entry.stat();
            if (before.size != after.size ||
                before.modified != after.modified ||
                await copied.length() != before.size) {
              throw FileSystemException(
                  'Legacy data changed during migration', entry.path);
            }
          }
        }
        await stage.rename(target.path);
        promoted = true;
      } finally {
        for (final handle in locks.values.toList().reversed) {
          await handle.close();
        }
        if (!promoted && await stage.exists()) {
          await stage.delete(recursive: true);
        }
      }
    } else {
      await target.create();
    }
  }
  // Never silently fall back to AppData when the portable folder is read-only.
  final probe = File(path.join(target.path, '.write-check-$pid'));
  try {
    await probe.writeAsString('', flush: true);
  } finally {
    if (await probe.exists()) await probe.delete();
  }
  return target;
}
