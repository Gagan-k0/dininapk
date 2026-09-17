import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineinapk/config/api_config.dart';
import 'package:dineinapk/services/api_client.dart';
import 'package:dineinapk/services/device_id_service.dart';
import 'package:dineinapk/services/menu_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceIdService.resetCache();
  });

  group('device id', () {
    test('is generated once and reused across app runs', () async {
      final first = await DeviceIdService().get();
      expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));

      DeviceIdService.resetCache(); // simulate a fresh app run
      expect(await DeviceIdService().get(), first);
    });

    test('two devices do not share an id', () async {
      final a = await DeviceIdService().get();
      SharedPreferences.setMockInitialValues({});
      DeviceIdService.resetCache();
      expect(await DeviceIdService().get(), isNot(a));
    });

    test('rides on every request as x-device-id', () {
      final h = ApiConfig.headers('tok', 'rest1', deviceId: 'abc123');
      expect(h['x-device-id'], 'abc123');
      expect(ApiConfig.headers('tok', 'rest1')['x-device-id'], isNull);
    });
  });

  group('table claim refusal', () {
    test('is recognised even though status.code is a word, not a number', () {
      final env = ApiEnvelope.parse({
        'status': {
          'code': 'table_claimed_by_another_device',
          'message': 'This table is being served by another device',
        },
        'data': {'held_by': 'device-2'},
      });
      expect(env.reason, 'table_claimed_by_another_device');
      expect(env.ok, isFalse);

      final err = ApiException(
        env.message,
        code: env.code,
        data: env.data,
        reason: env.reason,
      );
      expect(err.isTableClaimed, isTrue);
      expect(err.claimHeldBy, 'device-2');
    });

    test('an ordinary refusal is not mistaken for a claim', () {
      final env = ApiEnvelope.parse({
        'status': {'code': 422, 'message': 'no_cart'},
      });
      expect(env.reason, '');
      expect(ApiException(env.message, code: env.code).isTableClaimed, isFalse);
    });
  });

  group('menu cache freshness', () {
    test('a just-saved snapshot serves a table open without the catalog calls', () async {
      final cache = MenuCacheService();
      await cache.save(
        restaurantId: 'r1',
        categories: [
          {'_id': 'c1', 'category_name': 'Starters'},
        ],
        items: [
          {'_id': 'm1', 'name': 'Soup', 'price': 90},
        ],
        taxRows: [
          {'name': 'CGST', 'value_amount': 2.5},
        ],
        variants: [
          {'_id': 'v1', 'name': 'Full'},
        ],
        departments: [
          {'_id': 'd1', 'name': 'Kitchen'},
        ],
      );

      final snap = await cache.load('r1');
      expect(snap, isNotNull);
      expect(snap!.hasCatalog, isTrue);
      expect(snap.isFresh, isTrue);
      expect(snap.taxRows.single['name'], 'CGST');
      expect(snap.variants.single['_id'], 'v1');
      expect(snap.departments.single['name'], 'Kitchen');
    });

    test('a stale snapshot still paints but forces a refresh', () {
      final stale = CachedMenuSnapshot(
        categories: const [],
        items: const [],
        savedAt: DateTime(2026, 9, 17, 1),
      );
      expect(stale.isFreshAt(DateTime(2026, 9, 17, 9)), isFalse); // 8h old
      expect(stale.isFreshAt(DateTime(2026, 9, 17, 4)), isTrue); // 3h old
    });

    test('a snapshot with no timestamp is never treated as fresh', () {
      const noStamp = CachedMenuSnapshot(categories: [], items: []);
      expect(noStamp.isFresh, isFalse);
    });

    test('a snapshot missing items or tax is painted but never replaces the calls', () async {
      final cache = MenuCacheService();
      await cache.save(
        restaurantId: 'r1',
        categories: [
          {'_id': 'c1', 'category_name': 'Starters'},
        ],
        items: const [], // e.g. the menu call returned nothing this once
      );
      final snap = await cache.load('r1');
      expect(snap!.hasCatalog, isTrue); // still worth painting
      expect(snap.isSkippable, isFalse); // but the catalog must be re-fetched
    });

    test('a failed tax/department refresh never overwrites good cached rows', () async {
      final cache = MenuCacheService();
      const cats = [
        {'_id': 'c1', 'category_name': 'Starters'},
      ];
      const items = [
        {'_id': 'm1', 'name': 'Soup', 'price': 90},
      ];
      await cache.save(
        restaurantId: 'r1',
        categories: cats,
        items: items,
        taxRows: [
          {'name': 'CGST', 'value_amount': 2.5},
        ],
        departments: [
          {'_id': 'd1', 'name': 'Kitchen'},
        ],
      );
      // Next open: tax + departments 500'd, so they arrive empty.
      await cache.save(restaurantId: 'r1', categories: cats, items: items);

      final snap = await cache.load('r1');
      expect(snap!.taxRows.single['name'], 'CGST');
      expect(snap.departments.single['name'], 'Kitchen');
      expect(snap.isSkippable, isTrue);
    });

    test('another restaurant never reads this one cache', () async {
      final cache = MenuCacheService();
      await cache.save(
        restaurantId: 'r1',
        categories: [
          {'_id': 'c1', 'category_name': 'Starters'},
        ],
        items: const [],
      );
      expect(await cache.load('r2'), isNull);
    });
  });
}
