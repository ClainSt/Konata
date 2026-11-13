import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ccplayer/core/personal_scraper.dart';
import 'package:ccplayer/core/scan_activity.dart';

void main() {
  for (final mode in ['unique', 'late_alias', 'failure', 'cancel']) {
    test('Bangumi bounded detail batches: $mode', () async {
      var active = 0, peak = 0;
      var cancelled = false;
      final details = <int>[];
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(jsonEncode({
            'total': 8,
            'data': [
              for (var id = 1; id <= 8; id++)
                {'id': id, 'name': id == 1 ? 'Series' : 'Other $id', 'date': '2020-01-01'},
            ],
          }), 200);
        }
        final id = int.parse(request.url.path.split('/').last);
        details.add(id);
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        if (mode == 'cancel' && id == 1) cancelled = true;
        if (mode == 'failure' && id == 2) return http.Response('{}', 503);
        return http.Response(jsonEncode({
          'id': id,
          'name': id == 1 ? 'Series' : 'Other $id',
          'date': '2020-01-01',
          if (mode == 'late_alias' && id == 8)
            'infobox': [{'key': '别名', 'value': 'Series'}],
        }), 200);
      });
      final scraper = PersonalMetadataScraper(client: client);
      scraper.checkCancelled = () {
        if (cancelled) throw const ScanCancelled();
      };
      addTearDown(scraper.close);
      addTearDown(client.close);
      final result = scraper.matchBangumi('Series', 2020);
      if (mode == 'unique') {
        expect((await result)?['id'], 1);
      } else if (mode == 'cancel') {
        await expectLater(result, throwsA(isA<ScanCancelled>()));
      } else {
        await expectLater(result, throwsA(anything));
      }
      expect(peak, 2);
      expect(active, 0);
      expect(details, ['failure', 'cancel'].contains(mode) ? [1, 2] : List.generate(8, (i) => i + 1));
    });
  }
}
