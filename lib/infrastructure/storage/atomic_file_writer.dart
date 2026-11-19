import 'dart:io';

/// 跨平台（含 Windows 既有目标文件安全覆盖）同卷原子替换落盘工具（全仓唯一）。
///
/// 针对 Windows 平台上目标缓存文件已存在或短时被并发句柄占用的场景：
/// 1. 优先执行同卷 `rename` 原子发布；
/// 2. 当目标已存在导致 `FileSystemException` 时，先将旧目标移至同卷备份路径再原子发布新文件，
///    成功即删除备份，失败即回滚还原旧目标，严禁留下半包文件或丢失原有可用缓存；
/// 3. 遇短时共享冲突时最多退避重试两次。
abstract final class AtomicFileWriter {
  /// 将已完成完整性校验的同卷临时文件 [partFile] 原子替换发布至 [targetFile]。
  static Future<void> replaceFile(
    File partFile,
    File targetFile, {
    int? expectedLength,
  }) async {
    const retryDelaysMs = <int>[0, 20, 60];
    FileSystemException? lastError;

    for (var attempt = 0; attempt < retryDelaysMs.length; attempt++) {
      if (retryDelaysMs[attempt] > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: retryDelaysMs[attempt]),
        );
      }

      try {
        await partFile.rename(targetFile.path);
        return;
      } on FileSystemException catch (err) {
        lastError = err;
        if (!await targetFile.exists()) {
          continue;
        }
        // 目标文件已存在时使用“备份挪位 -> 原子发布 -> 清理备份”安全替换，失败自动回滚。
        final backupFile = File(
          '${targetFile.path}.bak.${DateTime.now().microsecondsSinceEpoch}_$attempt',
        );
        var movedOldToBackup = false;
        try {
          await targetFile.rename(backupFile.path);
          movedOldToBackup = true;
          await partFile.rename(targetFile.path);
          if (await backupFile.exists()) {
            await backupFile.delete().catchError((_) => backupFile);
          }
          return;
        } on FileSystemException catch (swapErr) {
          lastError = swapErr;
          if (movedOldToBackup &&
              !await targetFile.exists() &&
              await backupFile.exists()) {
            try {
              await backupFile.rename(targetFile.path);
            } on FileSystemException {
              // 极罕见竞争下由外层重试处理。
            }
          }
        }
      }
    }

    // 若多并发写入竞争期间已有其他写入者成功发布同长度有效文件，清理自身临时文件并视为成功。
    if (expectedLength != null &&
        expectedLength > 0 &&
        await targetFile.exists()) {
      final actualLen = await targetFile.length();
      if (actualLen == expectedLength) {
        if (await partFile.exists()) {
          await partFile.delete().catchError((_) => partFile);
        }
        return;
      }
    }

    throw lastError ??
        FileSystemException('同卷原子替换目标文件失败', targetFile.path);
  }
}
