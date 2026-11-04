import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/selected_scanner.dart';

void main() {
  test('collection selection groups videos by immediate child folder', () {
    final folder = SelectedScanner.workFolderFor(
      relativePath: '动画-单作品/86 (2021) {tmdb-100565}/[01].mkv',
      selectedRoot: '动画-单作品',
      mode: 'collection',
    );
    expect(folder, '动画-单作品/86 (2021) {tmdb-100565}');
  });
  test('single work selection includes directly contained videos', () {
    final folder = SelectedScanner.workFolderFor(
      relativePath: '动画-单作品/86 (2021) {tmdb-100565}/[01].mkv',
      selectedRoot: '动画-单作品/86 (2021) {tmdb-100565}',
      mode: 'work',
    );
    expect(folder, '动画-单作品/86 (2021) {tmdb-100565}');
  });
  test('local root work supports files directly inside folder', () {
    final folder = SelectedScanner.workFolderFor(
      relativePath: '[01].mkv',
      selectedRoot: '',
      mode: 'work',
      localRootName: '86',
    );
    expect(folder, '86');
  });
  test('collection does not classify its own files as works', () {
    expect(
      SelectedScanner.workFolderFor(
        relativePath: '动画-单作品/01.mkv',
        selectedRoot: '动画-单作品',
        mode: 'collection',
      ),
      isNull,
    );
  });
  test('selected work does not include a sibling folder', () {
    expect(
      SelectedScanner.workFolderFor(
        relativePath: '动画-单作品/Other/[01].mkv',
        selectedRoot: '动画-单作品/86',
        mode: 'work',
      ),
      isNull,
    );
  });
}
