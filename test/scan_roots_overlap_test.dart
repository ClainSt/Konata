import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/selected_scanner.dart';

void main() {
  Map<String, Object?> root(String path) => {'relative_path': path};
  test('scanning parent and child never double-counts nested videos', () {
    final selected = [
      root('Anime/SPs'),
      root('Anime'),
      root('Anime/Scans'),
      root('Anime2'),
      root('Anime/SPs'),
    ];
    final minimal = SelectedScanner.nonOverlappingRoots(selected);
    expect(minimal.map((e) => e['relative_path']).toSet(), {'Anime', 'Anime2'});
    expect(minimal.length, 2);
  });
  test('selecting the whole source supersedes every nested range', () {
    final minimal = SelectedScanner.nonOverlappingRoots([
      root('Anime/S01'),
      root('Anime'),
      root(''),
    ]);
    expect(minimal.length, 1);
    expect(minimal.single['relative_path'], '');
  });
}
