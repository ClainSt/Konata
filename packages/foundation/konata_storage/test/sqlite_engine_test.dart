import 'dart:async';
import 'dart:io';

import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('KonataSqliteEngine 核心能力', () {
    test('独立 PRAGMA user_version 多步迁移与外键/超时配置生效', () async {
      final engine = KonataSqliteEngine.openInMemory(
        databaseName: 'test_engine',
        migrations: <SqliteMigration>[
          SqliteMigration(
            targetVersion: 1,
            migrate: (db) {
              db.execute(
                'CREATE TABLE parents (id TEXT PRIMARY KEY, name TEXT NOT NULL);',
              );
            },
          ),
          SqliteMigration(
            targetVersion: 2,
            migrate: (db) {
              db.execute(
                'CREATE TABLE children ('
                'id TEXT PRIMARY KEY, '
                'parent_id TEXT NOT NULL REFERENCES parents(id) ON DELETE CASCADE'
                ');',
              );
            },
          ),
        ],
      );
      addTearDown(engine.close);

      expect(engine.userVersion, 2);
      expect(engine.select('PRAGMA foreign_keys;').first.columnAt(0), 1);
      expect(engine.select('PRAGMA busy_timeout;').first.columnAt(0), 5000);

      // 外键开启后插入悬空子记录应被 SQLite 拦截。
      expect(
        () => engine.execute(
          'INSERT INTO children (id, parent_id) VALUES (?, ?);',
          <Object?>['c1', 'missing_parent'],
        ),
        throwsA(isA<Object>()),
      );
    });

    test('watchQuery 响应式触发且事务回滚绝不广播伪变更', () async {
      final engine = KonataSqliteEngine.openInMemory(
        databaseName: 'test_watch',
        migrations: <SqliteMigration>[
          SqliteMigration(
            targetVersion: 1,
            migrate: (db) {
              db.execute(
                'CREATE TABLE items (id TEXT PRIMARY KEY, title TEXT NOT NULL);',
              );
              db.execute('CREATE TABLE other (id TEXT PRIMARY KEY);');
            },
          ),
        ],
      );
      addTearDown(engine.close);

      final snapshots = <List<String>>[];
      final sub = engine
          .watchQuery<List<String>>(
            tables: const <String>{'items'},
            query: (db) => <String>[
              for (final row in db.select(
                'SELECT title FROM items ORDER BY id ASC;',
              ))
                row['title'] as String,
            ],
          )
          .listen(snapshots.add);
      addTearDown(sub.cancel);

      await Future<void>.delayed(Duration.zero);
      expect(snapshots, equals(<List<String>>[<String>[]]));

      // 写入无关表不得误触发 items 订阅。
      engine.runTransaction((tx) {
        tx.execute(
          'INSERT INTO other (id) VALUES (?);',
          <Object?>['o1'],
          const <String>{'other'},
        );
      });
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, hasLength(1));

      // 事务中途抛异常回滚：数据库无残留且绝不广播 TableChangeBus。
      expect(
        () => engine.runTransaction((tx) {
          tx.execute(
            'INSERT INTO items (id, title) VALUES (?, ?);',
            <Object?>['1', '回滚条目'],
            const <String>{'items'},
          );
          throw StateError('模拟事务异常');
        }),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, hasLength(1));
      expect(engine.select('SELECT COUNT(*) FROM items;').first.columnAt(0), 0);

      // 正常提交后应精确触发一次新快照。
      engine.runTransaction((tx) {
        tx.execute(
          'INSERT INTO items (id, title) VALUES (?, ?);',
          <Object?>['1', '轻音少女'],
          const <String>{'items'},
        );
      });
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, hasLength(2));
      expect(snapshots.last, equals(<String>['轻音少女']));
    });

    test('文件库启用 WAL 且后台 Isolate 批量写入后主线程 watchQuery 自动刷新', () async {
      final tempDir = await Directory.systemTemp.createTemp('konata_eng_');
      addTearDown(() async {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      });

      final dbPath = p.join(tempDir.path, 'batch.db');
      final engine = KonataSqliteEngine.openFile(
        filePath: dbPath,
        databaseName: 'batch_test',
        migrations: <SqliteMigration>[
          SqliteMigration(
            targetVersion: 1,
            migrate: (db) {
              db.execute('CREATE TABLE entries (id INTEGER PRIMARY KEY);');
            },
          ),
        ],
      );
      addTearDown(engine.close);

      final journalMode =
          (engine.select('PRAGMA journal_mode;').first.columnAt(0) as String)
              .toLowerCase();
      expect(journalMode, 'wal');

      final counts = <int>[];
      final sub = engine
          .watchQuery<int>(
            tables: const <String>{'entries'},
            query: (db) =>
                db.select('SELECT COUNT(*) FROM entries;').first.columnAt(0)
                    as int,
          )
          .listen(counts.add);
      addTearDown(sub.cancel);

      await Future<void>.delayed(Duration.zero);
      expect(counts, equals(<int>[0]));

      final inserted = await engine.runWriteBatchInIsolate<int>(
        affectedTables: const <String>{'entries'},
        action: (bgDb) {
          final stmt = bgDb.prepare('INSERT INTO entries (id) VALUES (?);');
          try {
            for (var i = 1; i <= 25; i++) {
              stmt.execute(<Object?>[i]);
            }
          } finally {
            stmt.close();
          }
          return 25;
        },
      );

      await Future<void>.delayed(Duration.zero);
      expect(inserted, 25);
      expect(counts, equals(<int>[0, 25]));
    });
  });
}
