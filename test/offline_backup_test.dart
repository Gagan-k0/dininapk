import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dineinapk/services/auth_service.dart';
import 'package:dineinapk/services/draft_cart_store.dart';

/// The outbox's disk copies back up offline bills and unsent drafts — money
/// and sales — so they must be read back, and must survive logout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  OutboxFileStore.useDirectoryForTesting(
    Directory.systemTemp.createTempSync('outbox_test_'),
  );

  const rid = '64a000000000000000000001';
  const tid = '64b000000000000000000001';
  final store = DraftCartStore();

  OfflineSettlement bill(String key) => OfflineSettlement(
    restaurantId: rid,
    tableId: tid,
    key: key,
    paymentType: 'CASH',
    tableNumber: '9',
    printedTotal: 340,
    capturedAt: DateTime(2026, 9, 21, 17, 42),
    billNumber: 'OFF-A014-1',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await OutboxFileStore.clearAll();
  });

  test('an offline bill SharedPreferences lost comes back from disk', () async {
    await store.saveSettlement(bill('aa11'));
    SharedPreferences.setMockInitialValues({}); // prefs wiped

    final rows = await store.allSettlements(rid);
    expect(rows.map((s) => s.key), ['aa11']);
    expect(rows.single.printedTotal, 340);

    // ...and is written back, so the next read does not depend on the disk.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.startsWith('waiter_settle_')), hasLength(1));
  });

  test('an unreadable SharedPreferences row is replaced by its disk copy', () async {
    await store.saveSettlement(bill('bb22'));
    final prefs = await SharedPreferences.getInstance();
    final k = prefs.getKeys().singleWhere((k) => k.startsWith('waiter_settle_'));
    await prefs.setString(k, '{corrupted');

    final rows = await store.allSettlements(rid);
    expect(rows.single.key, 'bb22');
  });

  test('a row present in both is not listed twice', () async {
    await store.saveSettlement(bill('cc33'));
    await store.saveSettlement(bill('dd44'));
    expect(await store.allSettlements(rid), hasLength(2));
  });

  test('logout keeps the disk backup of offline bills', () async {
    await AuthService().saveSession(token: 't', restaurantId: rid);
    await store.saveSettlement(bill('ee55'));
    await AuthService().logout();
    SharedPreferences.setMockInitialValues({});

    expect((await store.allSettlements(rid)).single.key, 'ee55');
  });

  test('deleting a draft removes its disk copy too', () async {
    await store.save(
      TableDraft(
        restaurantId: rid,
        tableId: tid,
        key: 'k1',
        lines: const [
          DraftLine(lineId: 'l1', menuId: 'm1', name: 'Dosa', quantity: 1, unitPrice: 50),
        ],
      ),
    );
    await store.delete(rid, tid);
    expect(await OutboxFileStore.keys('waiter_draft_'), isEmpty);
  });
}
