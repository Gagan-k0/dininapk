import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineinapk/models/cart_model.dart';
import 'package:dineinapk/models/menu_model.dart';
import 'package:dineinapk/providers/auth_provider.dart';
import 'package:dineinapk/providers/pos_provider.dart';
import 'package:dineinapk/services/api_client.dart';
import 'package:dineinapk/services/api_service.dart';
import 'package:dineinapk/services/auth_service.dart';
import 'package:dineinapk/services/connectivity_service.dart';
import 'package:dineinapk/services/draft_cart_store.dart';
import 'package:dineinapk/services/offline_pricing.dart';
import 'package:dineinapk/utils/menu_filter.dart';

const testRid = '64a000000000000000000001';
const testTid = '64b000000000000000000001';
const testItem1Id = '64d000000000000000000001';
const testItem2Id = '64d000000000000000000002';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await OutboxFileStore.clearAll();
    ConnectivityService.instance.clearSignal();
    await ConnectivityService.instance.setSyncOn(true);
  });

  group('Domain 1: Authentication & Session Persistence', () {
    test('Session token save, restore, and logout draft retention', () async {
      final authService = AuthService();
      await authService.saveSession(
        token: 'jwt_token_123',
        restaurantId: testRid,
        restaurantName: 'The Fat Fox Bistro',
      );

      expect(await authService.getToken(), equals('jwt_token_123'));
      expect(await authService.getRestaurantId(), equals(testRid));

      // Save a draft order
      final store = DraftCartStore();
      final draft = TableDraft(
        restaurantId: testRid,
        tableId: testTid,
        key: 'key_123',
        lines: [
          DraftLine(
            lineId: 'l1',
            menuId: testItem1Id,
            name: 'Paneer Butter Masala',
            quantity: 2,
            unitPrice: 280,
          ),
        ],
      );
      await store.save(draft);

      // Perform logout
      await authService.logout();
      expect(await authService.getToken(), isNull);

      // Verify draft survives logout (important for offline sales history)
      final restoredDrafts = await store.all(testRid);
      expect(restoredDrafts.length, equals(1));
      expect(restoredDrafts.first.lines.first.name, equals('Paneer Butter Masala'));
    });

    test('Demo mode restricts live network operations', () async {
      final authProvider = AuthProvider();
      await authProvider.enterDemoMode();
      expect(authProvider.isDemoMode, isTrue);

      final authService = AuthService();
      final client = ApiClient(auth: authService);
      expect(
        () async => await client.get('/test'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('Domain 2: POS Menu Filtering, Pricing & Cart Engine', () {
    test('Menu Search and Category Filtering', () {
      final items = [
        MenuItem(id: '1', name: 'Chicken Tikka', categoryId: 'cat_starters', price: 320, attribute: 'Non-Veg'),
        MenuItem(id: '2', name: 'Paneer Tikka', categoryId: 'cat_starters', price: 280, attribute: 'Veg'),
        MenuItem(id: '3', name: 'Mango Lassi', categoryId: 'cat_drinks', price: 120, attribute: 'Veg'),
      ];

      final filteredStarters = filterMenuItems(
        items: items,
        categoryId: 'cat_starters',
        search: '',
      );
      expect(filteredStarters.length, equals(2));

      final filteredSearch = filterMenuItems(
        items: items,
        categoryId: null,
        search: 'lassi',
      );
      expect(filteredSearch.length, equals(1));
      expect(filteredSearch.first.name, equals('Mango Lassi'));
    });

    test('Exact Paisa-to-Paisa Offline Pricing Engine Audit', () {
      final totals = OfflinePricing.compute(
        foodSubtotal: 560.0,
        totalQuantity: 2,
        taxRows: [
          {
            'display_name': 'CGST',
            'value_amount': 2.5,
            'value_type': 'PERCENTAGE',
            'tax_type': 'FORWARD',
            'status': 1,
          },
          {
            'display_name': 'SGST',
            'value_amount': 2.5,
            'value_type': 'PERCENTAGE',
            'tax_type': 'FORWARD',
            'status': 1,
          },
        ],
        area: {
          'surgeType': 'flat',
          'surgeValue': 20.0,
          'isAcTaxable': true,
        },
        containerPrice: 30.0,
        discount: 50.0,
      );

      expect(totals.foodSubtotal, equals(560.0));
      expect(totals.areaCharge, equals(40.0));
      expect(totals.taxTotal, equals(30.0));
      expect(totals.discount, equals(50.0));
      expect(totals.containerPrice, equals(30.0));
      expect(totals.total, equals(610.0));
    });
  });

  group('Domain 3: Thermal Printer Routing & Ticket Generation', () {
    test('Department-based KOT Ticket Division', () {
      final foodItem = CartLineItem(
        id: '1',
        quantity: 2,
        item: MenuItem(id: testItem1Id, categoryId: 'c1', name: 'Naan', price: 40, attribute: 'Veg'),
      );
      final drinkItem = CartLineItem(
        id: '2',
        quantity: 1,
        item: MenuItem(id: testItem2Id, categoryId: 'c2', name: 'Mojito', price: 180, attribute: 'Veg'),
      );

      final pos = PosProvider();
      final groups = pos.buildKotGroups([foodItem, drinkItem]);

      expect(groups.length, greaterThanOrEqualTo(1));
      expect(groups.first.items.isNotEmpty, isTrue);
    });

    test('Provisional Offline Bill Number Generation', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('waiter_last_bill_no_$testRid', 1045);

      final nextNo = await OfflineBillNumbers.next(testRid);
      expect(OfflineBillNumbers.isProvisional(nextNo), isTrue);
      expect(nextNo, contains('1046'));
    });
  });

  group('Domain 4: Storage Engine Durability & Atomic Fallback', () {
    test('DraftCartStore atomic write and corrupted SharedPreferences recovery', () async {
      final store = DraftCartStore();
      final draft = TableDraft(
        restaurantId: testRid,
        tableId: testTid,
        key: 'key_audit_99',
        lines: [
          DraftLine(lineId: 'l9', menuId: testItem1Id, name: 'Biryani', quantity: 1, unitPrice: 350),
        ],
      );

      // Save draft (writes to both SharedPreferences and atomic disk file)
      await store.save(draft);

      // Simulate SharedPreferences string corruption (e.g. partial XML write during battery kill)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('waiter_draft_${testRid}_$testTid', '{corrupted_json_string');

      // Load draft should recover from OutboxFileStore atomic disk backup
      final recovered = await store.load(testRid, testTid);
      expect(recovered, isNotNull);
      expect(recovered!.key, equals('key_audit_99'));
      expect(recovered.lines.first.name, equals('Biryani'));
    });
  });

  group('Domain 5: Network Guard & Captive Portal Validation', () {
    test('Captive Portal HTML redirect is detected as network failure', () async {
      final mockClient = MockClient((req) async {
        return http.Response(
          '<html><head><title>Hotel Wi-Fi Login</title></head><body>Please log in</body></html>',
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });

      final authService = AuthService();
      final apiClient = ApiClient(auth: authService, httpClient: mockClient);

      bool caught = false;
      try {
        await apiClient.get('/restaurant/cart/offline-sync');
      } on ApiException catch (e) {
        caught = true;
        expect(e.isNetwork, isTrue);
        expect(e.message, contains('Captive portal'));
      }
      expect(caught, isTrue);
      expect(ConnectivityService.instance.state, equals(SyncState.offlineNoSignal));
    });
  });

  group('Domain 6: Full Offline-to-Online End-to-End Simulation', () {
    test('Complete Offline Order, KOT Print, Settle & Online Reconnect Sync', () async {
      ConnectivityService.instance.clearSignal();
      await ConnectivityService.instance.setSyncOn(true);

      var mockCart = <Map<String, dynamic>>[];
      final requests = <http.Request>[];

      final mockClient = MockClient((req) async {
        requests.add(req);
        final path = req.url.path;

        if (path.endsWith('/createcart')) {
          mockCart = [
            {
              '_id': 'cart_online_77',
              'table_status': 'RUNNING',
              'cartMenuData': [
                {'_id': 'l1', 'menu_id': testItem1Id, 'quantity': 2, 'individual_price': 200}
              ]
            }
          ];
          return http.Response(
            jsonEncode({
              'status': {'code': 200, 'message': 'ok'},
              'data': mockCart,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/listallcartmenus')) {
          return http.Response(
            jsonEncode({
              'status': {'code': 200, 'message': 'ok'},
              'data': mockCart,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/restaurant/cart/offline-sync')) {
          return http.Response(
            jsonEncode({
              'status': {'code': 200, 'message': 'ok'},
              'data': {'cart': {'_id': 'cart_online_77', 'table_status': 'RUNNING'}},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (path.endsWith('/restaurant/cart/offline-settle')) {
          return http.Response(
            jsonEncode({
              'status': {'code': 200, 'message': 'ok'},
              'data': {
                'settlement': {
                  '_id': 'settle_online_77',
                  'order_no': 'ORD-9901',
                  'total_price': 400.0,
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'status': {'code': 200, 'message': 'ok'},
            'data': {},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final authService = AuthService();
      await authService.saveSession(
        token: 'token_sync_test',
        restaurantId: testRid,
        restaurantName: 'Fatfox Test Cafe',
      );

      final apiClient = ApiClient(auth: authService, httpClient: mockClient);
      final apiService = ApiService(client: apiClient);
      final store = DraftCartStore();

      // 1. Create TableDraft and OfflineSettlement
      final draft = TableDraft(
        restaurantId: testRid,
        tableId: testTid,
        key: 'draft_key_99',
        lines: [
          DraftLine(lineId: 'l1', menuId: testItem1Id, name: 'Burger', quantity: 2, unitPrice: 200),
        ],
      );

      final settlement = OfflineSettlement(
        restaurantId: testRid,
        tableId: testTid,
        key: 'settle_key_99',
        paymentType: 'CASH',
        printedTotal: 400.0,
        capturedAt: DateTime.now(),
        billNumber: 'OFF-A1-1001',
        draft: draft,
      );
      await store.saveSettlement(settlement);

      expect(DraftCartStore.pendingSettlements.value, equals(1));

      // 2. Perform background sync when back online
      final pos = PosProvider(api: apiService, auth: authService);
      final sentCount = await pos.flushAllDrafts();

      expect(sentCount, greaterThanOrEqualTo(1));
      expect(requests.any((r) => r.url.path.endsWith('/offline-settle')), isTrue);
    });
  });
}
