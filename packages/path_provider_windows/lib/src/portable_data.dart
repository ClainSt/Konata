import 'dart:io';
import 'package:path/path.dart' as path;

/// 在打开数据库与设置前执行单次历史数据迁移；保留旧目录原貌，已存在的便携目录优先。
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
        // 存在另一个运行中实例时 SQLite 会持有文件锁，此时拒绝并发迁移以免拷贝脏库。
        for (final name in [
          for (final database in ['ccplayer.db', 'artwork/cache-index.sqlite'])
            for (final suffix in ['', '-wal', '-shm', '-journal'])
              '$database$suffix',
        ]) {
          final file = File(path.join(legacy.path, name));
          if (!await file.exists()) continue;
          final handle = await file.open();
          locks[path.normalize(file.path)] = handle;
          // SQLite 数据库文件锁区间位于高位偏移 `0x40000000`，超出普通文件默认 EOF 锁检测范围。
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
              // 持锁期间 Windows 会拒绝 `CopyFile` 打开第二个句柄，故直接通过当前持锁句柄分块读取拷贝。
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
  // 便携目录处于只读状态时严禁静默回退写入系统 `AppData`。
  final probe = File(path.join(target.path, '.write-check-$pid'));
  try {
    await probe.writeAsString('', flush: true);
  } finally {
    if (await probe.exists()) await probe.delete();
  }
  return target;
}
