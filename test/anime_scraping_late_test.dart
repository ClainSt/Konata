import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'anime_scraping_late_flow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'scope artwork, interval evidence and previewed merge round trip',
    () async {
      final root = await Directory.systemTemp.createTemp('konata-scrape-late-');
      try {
        await exerciseScrapeLibrary(root);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
