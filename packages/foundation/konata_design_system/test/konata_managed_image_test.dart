import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:konata_design_system/konata_design_system.dart';

void main() {
  test('目标宽度按档位向上规整并服从解码上限', () {
    expect(quantizeKonataImageWidth(193), 256);
    expect(quantizeKonataImageWidth(960), 960);
    expect(quantizeKonataImageWidth(961, maxWidth: 1000), 1000);
    expect(quantizeKonataImageWidth(9000), 3840);
  });

  test('缩略图缓存命中后调整淘汰顺序并过滤超大图', () {
    final lru = KonataThumbnailByteLru(maxEntries: 2, maxBytesPerEntry: 2);
    final image = Uint8List.fromList([1, 2]);
    lru.put('海报', image);
    lru.put('剧照', image);
    expect(lru.get('海报'), same(image));

    lru.put('背景', image);
    lru.put('原图', Uint8List(3));
    expect(lru.get('剧照'), isNull);
    expect(lru.get('原图'), isNull);
    expect(lru.get('海报'), same(image));
    expect(lru.get('背景'), same(image));

    lru.clear();
    expect(lru.get('背景'), isNull);
  });
}
