import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineinapk/models/menu_model.dart';
import 'package:dineinapk/providers/pos_provider.dart';
import 'package:dineinapk/services/api_client.dart';
import 'package:dineinapk/services/api_service.dart';
import 'package:dineinapk/services/auth_service.dart';
import 'package:dineinapk/services/connectivity_service.dart';
import 'package:dineinapk/services/draft_cart_store.dart';
import 'package:dineinapk/services/menu_cache_service.dart';
import 'package:dineinapk/widgets/held_items_bar.dart';

const tableId = '64b000000000000000000001';
const cartA = '64c000000000000000000001';
const cartB = '64c000000000000000000002';
const soup = '64d000000000000000000001';

DraftLine line(String id, {String? menu = soup, int qty = 1, List<Map<String, dynamic>> addons = const []}) =>
    DraftLine(lineId: id, menuId: menu, name: 'Soup', quantity: qty, unitPrice: 90, addons: addons);

Map<String, dynamic> envelope(Object? data) => {
  'status': {'code': 200, 'message': 'ok'},
  'data': data,
};

Map<String, dynamic> cartDoc(String id, List<Map<String, dynamic>> lines) => {
  '_id': id,
  'table_status': 'RUNNING',
  'total_price': 90 * lines.length,
  'cartMenuData': lines,
};

/// A tiny fake api-server: records every request and answers by path.
class FakeServer {
  final requests = <http.Request>[];
  List<Map<String, dynamic>> cart = [];
  Object? Function(http.Request)? failOn;

  int count(String path) => requests.where((r) => r.url.path.endsWith(path)).length;
  http.Request last(String path) => requests.lastWhere((r) => r.url.path.endsWith(path));

  late final client = MockClient((req) async {
    requests.add(req);
    final fail = failOn?.call(req);
    if (fail is Future) await fail;
    if (fail is Exception) throw fail;
    if (fail is Map) return http.Response(jsonEncode(fail), 200);
    final p = req.url.path;
    Object? data = const [];
    if (p.contains('/table/view')) data = {'table_id': req.url.pathSegments.last, 'table_number': '5'};
    if (p.endsWith('/listallcartmenus')) data = cart;
    if (p.endsWith('/createcart')) {
      cart = [cartDoc(cartA, [{'_id': 'l1', 'menu_id': soup, 'quantity': 1, 'kot_status': 0}])];
      data = cart;
    }
    if (p.endsWith('/updatecartmenuquantity')) data = cart;
    return http.Response(jsonEncode(envelope(data)), 200);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('draft rules', () {
    test('identical taps merge like the server; different add-ons do not', () {
      var d = TableDraft.start('r1', tableId, cartA);
      d = d.add(line('a')).add(line('b')).add(line('c', addons: [{'addonvalue_id': 'x'}]));
      expect(d.lines.length, 2);
      expect(d.lines.first.quantity, 2);
    });

    test('extras merge only on the same name and price', () {
      const e1 = DraftLine(lineId: '1', menuId: null, name: 'Water', quantity: 1, unitPrice: 20, isExtra: true);
      const e2 = DraftLine(lineId: '2', menuId: null, name: 'Water', quantity: 1, unitPrice: 30, isExtra: true);
      expect(e1.sameItemAs(e2), isFalse);
      expect(e1.sameItemAs(e1), isTrue);
      expect(e1.sameItemAs(line('3', menu: null)), isFalse);
    });

    test('the idempotency key survives edits and restarts', () {
      final d = TableDraft.start('r1', tableId, cartA);
      final edited = d.add(line('a')).setQuantity('a', 4).setQuantity('a', 0).add(line('b'));
      expect(edited.key, d.key);
      expect(TableDraft.fromJson(jsonDecode(jsonEncode(edited.toJson()))).key, d.key);
    });

    test('a draft is never read for another restaurant', () async {
      SharedPreferences.setMockInitialValues({});
      final store = DraftCartStore();
      await store.save(TableDraft.start('r1', tableId, cartA).add(line('a')));
      expect(await store.load('r2', tableId), isNull);
      expect((await store.load('r1', tableId))!.itemCount, 1);
    });

    test('logout keeps unsent drafts but drops cart snapshots', () async {
      SharedPreferences.setMockInitialValues({});
      final store = DraftCartStore();
      await store.save(TableDraft.start('r1', tableId, cartA).add(line('a')));
      await store.saveSnapshot('r1', tableId, cart: [{'customer_name': 'Asha'}]);
      await AuthService().logout();
      expect(await store.load('r1', tableId), isNotNull);
      expect(await store.loadSnapshot('r1', tableId), isNull);
    });
  });

  group('POS cart', () {
    late FakeServer server;
    late PosProvider pos;
    final item = MenuItem.fromJson({'_id': soup, 'name': 'Soup', 'price': 90});

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await AuthService().saveSession(token: 'tok', restaurantId: 'r1');
      await ConnectivityService.instance.load();
      ConnectivityService.instance.clearSignal();
      await MenuCacheService().save(
        restaurantId: 'r1',
        categories: [{'_id': 'c1', 'category_name': 'Soups'}],
        items: [{'_id': soup, 'name': 'Soup', 'price': 90}],
        taxRows: [{'_id': 't1', 'name': 'GST', 'value_type': 'percentage', 'value_amount': 5}],
      );
      server = FakeServer();
      final auth = AuthService();
      pos = PosProvider(
        api: ApiService(auth: auth, client: ApiClient(auth: auth, httpClient: server.client)),
        auth: auth,
      );
    });

    Future<void> open() => pos.loadTableAndMenu(tableId, 'area1');

    test('taps on an open order send nothing until KOT, then one batch', () async {
      server.cart = [cartDoc(cartA, [{'_id': 'l0', 'menu_id': 'other', 'quantity': 1, 'kot_status': 1}])];
      await open();
      final before = server.requests.length;

      for (var i = 0; i < 3; i++) {
        expect(await pos.addItemToCart(item), isTrue);
      }
      expect(server.requests.length, before, reason: 'taps must not hit the server');
      expect(pos.draft!.lines.single.quantity, 3);
      expect(pos.totalItemCount, 4);

      await pos.sendKotOrder();
      expect(server.count('/createcart'), 0);
      expect(server.count('/offline-sync'), 1);
      final sync = server.last('/offline-sync');
      expect(sync.headers['Idempotency-Key'], isNotEmpty);
      expect((jsonDecode(sync.body)['lines'] as List).single['quantity'], 3);
      expect(pos.draft, isNull);
      expect(await DraftCartStore().load('r1', tableId), isNull);
    });

    test('an empty table: the first tap opens the cart, later taps stay local', () async {
      await open();
      await pos.addItemToCart(item);
      expect(server.count('/createcart'), 1);
      final before = server.requests.length;
      await pos.addItemToCart(item);
      expect(server.requests.length, before);
      expect(pos.draft!.baselineCartId, cartA);
    });

    test('a table that turned over is never billed with old items', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item);
      server.cart = [cartDoc(cartB, [])]; // settled and re-seated meanwhile

      expect(await pos.flushDraft(), isFalse);
      expect(server.count('/offline-sync'), 0);
      expect(pos.draft!.conflict, isTrue);
      expect((await DraftCartStore().load('r1', tableId))!.conflict, isTrue);
    });

    test('a lost response is retried under the same key', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item);
      server.failOn = (r) => r.url.path.endsWith('/offline-sync') ? const SocketException('drop') : null;
      expect(await pos.flushDraft(), isFalse);
      final firstKey = server.last('/offline-sync').headers['Idempotency-Key'];

      server.failOn = null;
      expect(await pos.flushDraft(), isTrue);
      expect(server.last('/offline-sync').headers['Idempotency-Key'], firstKey);
    });

    test('409 conflict parks the draft instead of re-sending', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item);
      server.failOn = (r) => r.url.path.endsWith('/offline-sync')
          ? {'status': {'code': 409, 'message': 'conflict'}}
          : null;
      expect(await pos.flushDraft(), isFalse);
      expect(pos.draft!.conflict, isTrue);
      server.failOn = null;
      expect(await pos.flushDraft(), isFalse);
      expect(server.count('/offline-sync'), 1);
    });

    test('an unanswered createcart is recognised, not sent twice', () async {
      await open();
      await ConnectivityService.instance.setSyncOn(false);
      await pos.addItemToCart(item); // offline: no cart, goes to the draft
      await ConnectivityService.instance.setSyncOn(true);

      server.failOn = (r) {
        if (!r.url.path.endsWith('/createcart')) return null;
        server.cart = [cartDoc(cartA, [{'_id': 'l1', 'menu_id': soup, 'quantity': 1, 'individual_price': 90, 'kot_status': 0}])];
        return const SocketException('response lost');
      };
      expect(await pos.flushDraft(), isFalse);
      expect(pos.draft!.creatingLine, isNotNull);

      server.failOn = null;
      expect(await pos.flushDraft(), isTrue);
      expect(server.count('/createcart'), 1);
      expect(server.count('/offline-sync'), 0, reason: 'nothing else was waiting');
    });

    test('Sync off: a known table opens from the tablet and taps are kept', () async {
      server.cart = [cartDoc(cartA, [{'_id': 'l0', 'menu_id': soup, 'quantity': 2, 'kot_status': 1}])];
      await open(); // saves the snapshot
      await ConnectivityService.instance.setSyncOn(false);
      final sent = server.requests.length;

      pos = PosProvider(api: ApiService(client: ApiClient(httpClient: server.client)));
      await open();
      expect(pos.errorMessage, isNull);
      expect(pos.cartId, cartA);
      expect(await pos.addItemToCart(item), isTrue);
      expect(server.requests.length, sent);
      expect(await pos.sendKotOrder(), isFalse);
      expect(pos.draft!.itemCount, 1);
    });

    test('floor bill is refused while a table has unsent items', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item);
      final err = await pos.printBillForFloorTable(tableId: tableId, areaId: 'area1');
      expect(err, contains('not sent'));
    });

    test('opening another table offline never inherits the previous table', () async {
      const other = '64b000000000000000000099';
      server.cart = [cartDoc(cartA, [])];
      await open(); // table X online
      await ConnectivityService.instance.setSyncOn(false);
      await pos.loadTableAndMenu(other, 'area1'); // table Y, never seen
      expect(pos.resolvedTableId, other);
      expect(pos.cartId, isEmpty);
      await pos.addItemToCart(item);
      expect(await DraftCartStore().load('r1', other), isNotNull);
      expect(await DraftCartStore().load('r1', tableId), isNull);
    });

    test('leaving the table while it sends never touches the next table', () async {
      const other = '64b000000000000000000099';
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item);
      server.failOn = (r) {
        if (!r.url.path.endsWith('/offline-sync')) return null;
        // The next table has an order of its own, fully loaded before the send answers.
        server.cart = [cartDoc(cartA, [{'_id': 'y1', 'menu_id': soup, 'quantity': 1, 'kot_status': 0}])];
        return pos.loadTableAndMenu(other, 'area1');
      };
      expect(await pos.sendKotOrder(), isFalse);
      expect(server.count('/setcartstatus'), 0);
      expect(pos.draft, isNull, reason: 'X\'s draft must not be painted on Y');
      expect(await DraftCartStore().load('r1', tableId), isNull);
    });

    test('a tap while items are being sent is refused, not silently lost', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item);
      Future<bool>? tapDuringSend;
      server.failOn = (r) {
        if (r.url.path.endsWith('/offline-sync')) tapDuringSend = pos.addItemToCart(item);
        return null;
      };
      expect(await pos.flushDraft(), isTrue);
      expect(await tapDuringSend, isFalse);
    });

    test('an item whose createcart went unanswered is locked', () async {
      await open();
      server.failOn = (r) => r.url.path.endsWith('/createcart') ? const SocketException('lost') : null;
      await pos.addItemToCart(item); // falls back to a locked pending item
      final pending = pos.draft!.creatingLine!;
      expect(await pos.removeCartItem('draft:${pending.lineId}'), isFalse);
      expect(pos.draft!.creatingLine, isNotNull);
    });

    test('after a send whose refresh failed, KOT re-reads the cart first', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item);
      var synced = false;
      server.failOn = (r) {
        if (r.url.path.endsWith('/offline-sync')) {
          synced = true;
          server.cart = [cartDoc(cartA, [{'_id': 'l9', 'menu_id': soup, 'quantity': 1, 'kot_status': 0}])];
        }
        if (synced && r.url.path.endsWith('/listallcartmenus')) return const SocketException('drop');
        return null;
      };
      expect(await pos.sendKotOrder(), isFalse);
      expect(server.count('/setcartstatus'), 0);

      server.failOn = null;
      await pos.sendKotOrder();
      expect(server.count('/offline-sync'), 1, reason: 'never sent twice');
      final kot = server.requests.where((r) => r.url.path.endsWith('/setcartstatus')).first;
      expect(jsonDecode(kot.body)['table_status'] ?? jsonDecode(kot.body)['tableStatus'], 'KOT');
    });

    test('a refused createcart puts the item back so it can be removed', () async {
      await open();
      await ConnectivityService.instance.setSyncOn(false);
      await pos.addItemToCart(item);
      await ConnectivityService.instance.setSyncOn(true);
      server.failOn = (r) => r.url.path.endsWith('/createcart')
          ? {'status': {'code': 422, 'message': 'menu_inactive'}}
          : null;
      expect(await pos.flushDraft(), isFalse);
      final d = pos.draft!;
      expect(d.creatingLine, isNull);
      expect(await pos.removeCartItem('draft:${d.lines.single.lineId}'), isTrue);
      expect(pos.draft, isNull);
    });

    test('an unanswered first item is not re-created after its order closed', () async {
      await open();
      server.failOn = (r) => r.url.path.endsWith('/createcart') ? const SocketException('timeout') : null;
      await pos.addItemToCart(item); // may have reached the server
      server.failOn = null;
      server.cart = []; // that order was billed and released elsewhere

      expect(await pos.flushDraft(), isFalse);
      expect(server.count('/createcart'), 1, reason: 'never a second copy');
      expect(pos.draft!.conflict, isTrue);
      // Parked: the waiter can now remove it.
      expect(await pos.removeCartItem('draft:${pos.draft!.creatingLine!.lineId}'), isTrue);
      expect(pos.draft, isNull);
    });

    test('a bill is never printed from a cart that missed the sent items', () async {
      server.cart = [cartDoc(cartA, [{'_id': 'l0', 'menu_id': soup, 'quantity': 1, 'kot_status': 1, 'kotprint_status': 1}])];
      await open();
      await pos.addItemToCart(item);
      var synced = false;
      server.failOn = (r) {
        if (r.url.path.endsWith('/offline-sync')) synced = true;
        if (synced && r.url.path.endsWith('/listallcartmenus')) return const SocketException('drop');
        return null;
      };
      expect(await pos.flushDraft(), isFalse);
      expect(pos.canRelease, isFalse);
      expect(await pos.printBill(), contains('could not be refreshed'));
      expect(server.count('/vieworder-save'), 0);
    });

    test('Send now sends every table, skips held ones, and updates the count', () async {
      const t2 = '64b000000000000000000002';
      const t3 = '64b000000000000000000003';
      final store = DraftCartStore();
      server.cart = [cartDoc(cartA, [])];
      await store.save(TableDraft.start('r1', t2, cartA).add(line('a')));
      await store.save(TableDraft.start('r1', t3, cartA).add(line('b')).copyWith(conflict: true));
      expect(DraftCartStore.pendingTables.value, 2);

      expect(await pos.flushAllDrafts(), 1);
      expect(server.count('/offline-sync'), 1);
      expect(jsonDecode(server.last('/offline-sync').body)['table_id'], t2);
      expect(await store.load('r1', t2), isNull);
      expect((await store.load('r1', t3))!.conflict, isTrue);
      expect(DraftCartStore.pendingTables.value, 1);
    });

    test('nothing is sent in the background without a known tax', () async {
      SharedPreferences.setMockInitialValues({});
      await AuthService().saveSession(token: 'tok', restaurantId: 'r1');
      await DraftCartStore().save(TableDraft.start('r1', tableId, cartA).add(line('a')));
      server.cart = [cartDoc(cartA, [])];
      final fresh = PosProvider(api: ApiService(client: ApiClient(httpClient: server.client)));
      expect(await fresh.flushAllDrafts(), 0);
      expect(server.count('/offline-sync'), 0);
    });

    test('coming back online sends waiting items', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await ConnectivityService.instance.setSyncOn(false);
      await pos.addItemToCart(item);
      ConnectivityService.instance.onBackOnline = () => pos.flushAllDrafts();
      addTearDown(() => ConnectivityService.instance.onBackOnline = null);
      await ConnectivityService.instance.setSyncOn(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.count('/offline-sync'), 1);
    });

    test('Send to current order re-keys and sends a held draft', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item);
      final oldKey = pos.draft!.key;
      server.cart = [cartDoc(cartB, [])];
      expect(await pos.flushDraft(), isFalse); // held: order changed

      expect(await pos.resendDraft(), isTrue);
      final sync = server.last('/offline-sync');
      expect(sync.headers['Idempotency-Key'], isNot(oldKey));
      expect(pos.draft, isNull);
    });

    test('Discard drops held items for good', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item);
      server.cart = [];
      await pos.flushDraft();
      await pos.discardDraft();
      expect(pos.draft, isNull);
      expect(await DraftCartStore().load('r1', tableId), isNull);
      expect(DraftCartStore.pendingTables.value, 0);
    });

    testWidgets('held bar fits a phone and Discard asks first', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        server.cart = [cartDoc(cartA, [])];
        await open();
        await pos.addItemToCart(item);
        server.cart = [];
        await pos.flushDraft();
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Column(children: [HeldItemsBar(pos: pos)])),
      ));
      expect(find.textContaining('1 unsent item held'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(find.text('Discard held items?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(pos.draft, isNotNull);
    });

    test('Send now re-reads each table: items discarded meanwhile are not sent', () async {
      const t2 = '64b000000000000000000002';
      const t3 = '64b000000000000000000003';
      final store = DraftCartStore();
      server.cart = [cartDoc(cartA, [])];
      await open(); // tax known
      await store.save(TableDraft.start('r1', t2, cartA).add(line('a')));
      await store.save(TableDraft.start('r1', t3, cartA).add(line('b')));
      server.failOn = (r) {
        // While table 2 sends, the waiter discards table 3 elsewhere.
        if (r.url.path.endsWith('/offline-sync')) return store.delete('r1', t3);
        return null;
      };
      expect(await pos.flushAllDrafts(), 1);
      expect(server.count('/offline-sync'), 1);
    });

    test('after switching restaurant, the old restaurant\'s items are never sent', () async {
      server.cart = [cartDoc(cartA, [])];
      await open();
      await pos.addItemToCart(item); // r1 draft
      await AuthService().logout();
      await AuthService().saveSession(token: 'tok2', restaurantId: 'r2');
      expect(await pos.flushAllDrafts(), 0);
      expect(server.count('/offline-sync'), 0);
      expect(DraftCartStore.pendingTables.value, 0);
    });

    test('a background send for another table does not block taps here', () async {
      const t2 = '64b000000000000000000002';
      server.cart = [cartDoc(cartA, [])];
      await open();
      await DraftCartStore().save(TableDraft.start('r1', t2, cartA).add(line('a')));
      Future<bool>? tapHere;
      server.failOn = (r) {
        if (r.url.path.endsWith('/offline-sync')) tapHere = pos.addItemToCart(item);
        return null;
      };
      await pos.flushAllDrafts();
      expect(await tapHere, isTrue);
      expect(pos.draft!.itemCount, 1);
    });

    test('a background problem on another table never shows on this screen', () async {
      const t2 = '64b000000000000000000002';
      server.cart = [cartDoc(cartA, [])];
      await open();
      await DraftCartStore().save(TableDraft.start('r1', t2, cartB).add(line('a')));
      await pos.flushAllDrafts(); // t2's order changed → parked
      expect(pos.errorMessage, isNull);
      expect((await DraftCartStore().load('r1', t2))!.conflict, isTrue);
    });
  });
}
