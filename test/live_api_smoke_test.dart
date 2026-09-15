// Live smoke test against the real backend through the app's own service code.
//
// Opt-in only (hits the network):
//   FATFOX_LIVE=1 flutter test test/live_api_smoke_test.dart
//
// Verifies the handoff checklist without a device:
//   * staff-login is used when Restaurant No. is set
//   * floor returns the expected areas/tables for that restaurant
//   * opening a table loads menu + cart/order content
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineinapk/providers/auth_provider.dart';
import 'package:dineinapk/providers/pos_provider.dart';
import 'package:dineinapk/providers/table_provider.dart';
import 'package:dineinapk/services/api_client.dart';
import 'package:dineinapk/services/api_service.dart';
import 'package:dineinapk/services/auth_service.dart';

void main() {
  final live = Platform.environment['FATFOX_LIVE'] == '1';
  final user = Platform.environment['FATFOX_USER'] ?? 'test';
  final pass = Platform.environment['FATFOX_PASS'] ?? 'test';
  final restNo = Platform.environment['FATFOX_RESTAURANT_NO'] ?? '10000';

  group('live API smoke', () {
    late ApiService api;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // flutter_test installs a mock HttpClient that answers 400 to everything;
      // this suite is explicitly live, so restore real networking.
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      api = ApiService();
    });

    test('staff-login is used when Restaurant No. is set', () async {
      final res = await api.login(user, pass, restaurantNo: restNo);
      expect(res['status']?['code'], 200, reason: res.toString());
      final u = res['data']?['user'] as Map?;
      expect(u?['restaurant_no']?.toString(), restNo);
      expect(u?['usertype'], 'subadmin');
      // Real app path: AuthProvider.login persists the session used by ApiService.
      final authProv = AuthProvider();
      final ok = await authProv.login(
        email: user,
        password: pass,
        baseUrl: '',
        restaurantNo: restNo,
      );
      expect(ok, isTrue, reason: authProv.errorMessage);
      expect(await AuthService().getToken(), isNotEmpty);
      expect(await AuthService().getRestaurantId(), u?['restaurant_id']);
    });

    test('floor loads areas and tables for the staff restaurant', () async {
      final areas = await api.getAreas();
      final tables = await api.getTables();
      // ignore: avoid_print
      print('areas=${areas.length} tables=${tables.length}');
      expect(areas.length, 5);
      expect(tables.length, 40);
      expect(areas.every((a) => a.name.isNotEmpty), isTrue,
          reason: 'area name must map from area_name');
      expect(tables.every((t) => t.areaId.isNotEmpty), isTrue);
    });

    test('opening a table loads menu, table details and cart', () async {
      final tables = await api.getTables();
      final occupied = tables.where((t) => t.isOccupied).toList();
      final target = occupied.isNotEmpty ? occupied.first : tables.first;
      final pos = PosProvider();
      await pos.loadTableAndMenu(target.id, target.areaId);
      // ignore: avoid_print
      print('table=${target.tableNumber} status=${target.tableStatus} '
          'cats=${pos.categories.length} items=${pos.filteredMenuItems.length} '
          'cartItems=${pos.cartMenuItems.length} total=${pos.grandTotal}');
      expect(pos.errorMessage, isNull);
      expect(pos.cartError, isNull);
      expect(pos.categories, isNotEmpty);
      expect(pos.filteredMenuItems, isNotEmpty);
      expect(pos.tableDetails, isNotNull);
      if (occupied.isNotEmpty) {
        expect(pos.cartMenuItems, isNotEmpty,
            reason: 'occupied table must expose its cart lines');
        expect(pos.grandTotal, greaterThan(0),
            reason: 'grand total must come from cart.total_price');
      }
    });

    test('a bad token is an auth error, never an empty floor', () async {
      await AuthService().saveSession(
        token: 'expired.token.value',
        restaurantId: 'x',
      );
      var expiredFired = false;
      ApiClient.onSessionExpired = (_) => expiredFired = true;
      final prov = TableProvider();
      await prov.loadDashboardData();
      expect(prov.sessionExpired, isTrue, reason: prov.errorMessage);
      expect(prov.tables, isEmpty);
      expect(expiredFired, isTrue);
      ApiClient.onSessionExpired = null;
    });
  }, skip: live ? false : 'set FATFOX_LIVE=1 to run against the live API');
}
