import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/auto_classifier.dart';

void main() {
  test('arbitrary collection depth reaches unmarked work and keeps extras', () {
    for (final prefix in ['未添加TMDB ID/弹丸论破系列', '大目录/收藏/动画/未添加TMDB ID/弹丸论破系列']) {
      for (final suffix in ['[LoliHouse] Danganronpa 3 - Mirai Hen - 01.mkv', 'SPs/Bonus/PV01.mkv', 'Season 01/01.mkv']) {
        expect(AutoClassifier.decide(selectedRoot: '', relativePath: '$prefix/弹丸论破3/$suffix',
          rootHasDirectVideo: false, localRootName: '')?.folder, '$prefix/弹丸论破3');
      }
    }
  });
  AutoWork? classify(
    String root,
    String file, {
    bool direct = false,
    String local = '',
  }) => AutoClassifier.decide(
    selectedRoot: root,
    relativePath: file,
    rootHasDirectVideo: direct,
    localRootName: local,
  );

  test('collection scope: immediate anime folders become separate works', () {
    final result = classify(
      '动画-单作品',
      '动画-单作品/86 (2021) {tmdb-100565}/[01].mkv',
    );
    expect(result?.folder, '动画-单作品/86 (2021) {tmdb-100565}');
    expect(result?.needsReview, false);
  });
  test('title and year without TMDB ID still require review', () {
    final result = AutoClassifier.decide(
      selectedRoot: '动画-单作品',
      relativePath: '动画-单作品/某作品 (2021)/01.mkv',
      rootHasDirectVideo: false,
      localRootName: '',
    );
    expect(result?.folder, '动画-单作品/某作品 (2021)');
    expect(result?.needsReview, true);
  });
  test('single work root with directly contained videos', () {
    final result = classify('动画-单作品/86', '动画-单作品/86/[01].mkv', direct: true);
    expect(result?.folder, '动画-单作品/86');
    expect(result?.needsReview, true);
  });
  test('season and extras stay assigned to parent work', () {
    final result = classify('动画-单作品/86', '动画-单作品/86/Season 01/[01].mkv');
    expect(result?.folder, '动画-单作品/86');
  });
  test('a nested TMDB marker overrides series container', () {
    final result = classify(
      '动画-多作品',
      '动画-多作品/某系列/第二季 (2024) {tmdb-123456}/S02E01.mkv',
    );
    expect(result?.folder, '动画-多作品/某系列/第二季 (2024) {tmdb-123456}');
    expect(result?.needsReview, false);
  });
  test('root selection skips generic collection directory', () {
    final result = classify('', '动画-单作品/作品A/[01].mkv');
    expect(result?.folder, '动画-单作品/作品A');
    expect(result?.needsReview, true);
  });
  test('direct local single-work files are recognized', () {
    final result = classify(
      '',
      '01.mkv',
      direct: true,
      local: '86 (2021) {tmdb-100565}',
    );
    expect(result?.folder, '86 (2021) {tmdb-100565}');
    expect(result?.needsReview, false);
  });
  test('file outside selected path is excluded', () {
    expect(classify('动画-单作品/86', '动画-单作品/Other/[01].mkv'), isNull);
  });
  test(
    'video in a generic collection root is retained for file-level review',
    () {
      expect(
        classify('动画-单作品', '动画-单作品/unknown.mkv', direct: true)?.folder,
        '动画-单作品/@unclassified',
      );
    },
  );
  test('WMV video remains indexed for metadata review', () {
    expect(
      classify('动画-单作品', '动画-单作品/Title/episode.WMV')?.folder,
      '动画-单作品/Title',
    );
  });
}
