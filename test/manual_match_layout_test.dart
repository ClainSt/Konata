import 'dart:io';
import 'package:ccplayer/core/catalog.dart';
import 'package:ccplayer/core/image_store.dart';
import 'package:ccplayer/core/optional_features.dart';
import 'package:ccplayer/l10n/app_localizations.dart';
import 'package:ccplayer/main.dart';
import 'package:ccplayer/ui/nipaplay_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final size in [
      const Size(320, 640),
      const Size(844, 390),
      const Size(1366, 900),
    ]) {
      testWidgets(
        'manual match uses highlight and a separate search button $platform $size',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            OptionalFeatures.preferenceKey: '{}',
          });
          final root = (await tester.runAsync(() async {
            final root = await Directory.systemTemp.createTemp(
              'konata-match-ui-',
            );
            await Catalog.instance.initialize(dataDirectory: root);
            await Catalog.instance.db.insert('works', {
              'id': 'match-work',
              'title': '86 长标题 Long title',
            });
            await Catalog.instance.reload();
            return root;
          }))!;
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          await tester.binding.setSurfaceSize(size);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            await tester.binding.setSurfaceSize(null);
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            await tester.runAsync(() async {
              await ImageStore.close();
              await Catalog.instance.db.close();
              await root.delete(recursive: true);
            });
          });
          await tester.pumpWidget(
            MaterialApp(
              locale: const Locale('zh'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              theme: NipaPlayStyle.theme(
                Brightness.light,
              ).copyWith(platform: platform),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
              home: const WorkPage(workId: 'match-work'),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('detail-more-button')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('编辑元数据'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('metadata-search-bind')));
          await tester.pumpAndSettle();
          final provider = find.byKey(const ValueKey('manual-match-provider'));
          expect(
            tester.widget<SegmentedButton<String>>(provider).showSelectedIcon,
            false,
          );
          final query = find.byKey(const ValueKey('manual-match-query'));
          await tester.ensureVisible(query);
          await tester.pumpAndSettle();
          expect(
            tester
                    .getRect(find.byKey(const ValueKey('manual-match-search')))
                    .left -
                tester.getRect(query).right,
            greaterThanOrEqualTo(12),
          );
          await tester.ensureVisible(provider);
          await tester.tap(
            find.descendant(of: provider, matching: find.text('Bangumi')),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(query).decoration!.labelText,
            '名称或 Bangumi ID',
          );
          expect(tester.widget<SegmentedButton<String>>(provider).selected, {
            'bangumi',
          });
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
