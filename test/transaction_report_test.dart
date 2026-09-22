import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dineinapk/services/csv_export_service.dart';
import 'package:dineinapk/services/draft_cart_store.dart';
import 'package:dineinapk/views/reports/transaction_report_screen.dart';

void main() {
  final day = DateTime(2026, 9, 21);
  final from = day;
  final to = DateTime(2026, 9, 21, 23, 59, 59);

  const line = DraftLine(
    lineId: 'l1',
    menuId: 'm1',
    name: 'Dosa',
    quantity: 2,
    unitPrice: 50,
  );

  OfflineSettlement settle({
    bool synced = false,
    bool acknowledged = false,
    String? cartId,
    String? orderId,
    String? orderNo,
    String? lastError,
    DateTime? lastTriedAt,
    DateTime? at,
  }) => OfflineSettlement(
    restaurantId: 'r1',
    tableId: 't1',
    key: 'k-${orderId ?? at ?? 'x'}',
    paymentType: 'CASH',
    tableNumber: '5',
    printedTotal: 105,
    capturedAt: at ?? DateTime(2026, 9, 21, 13, 0),
    billNumber: 'OFF-AB12-7',
    cartId: cartId,
    synced: synced,
    acknowledged: acknowledged,
    orderId: orderId,
    orderNo: orderNo,
    lastError: lastError,
    lastTriedAt: lastTriedAt,
    draft: TableDraft(
      restaurantId: 'r1',
      tableId: 't1',
      key: 'd',
      printedLines: const [line],
    ),
  );

  List<Map<String, dynamic>> merge(
    List<Map<String, dynamic>>? online,
    List<OfflineSettlement> s,
  ) => TransactionReportScreen.mergeOrders(
    online: online,
    settlements: s,
    from: from,
    to: to,
  );

  test('server unreachable still lists offline bills', () {
    final rows = merge(null, [settle()]);
    expect(rows, hasLength(1));
    expect(rows.single['_isOffline'], true);
    expect(rows.single['_syncStatus'], 'Offline - pending sync');
  });

  test('synced bill whose server order is listed is not counted twice', () {
    final online = [
      {'_id': 'o1', 'order_no': '101', 'total_price': 105,
       'createdAt': '2026-09-21T07:30:00.000Z'},
    ];
    final rows = merge(online, [settle(synced: true, orderId: 'o1')]);
    expect(rows, hasLength(1));
    expect(rows.single['_id'], 'o1');
  });

  test('synced bill missing from the server list is kept', () {
    final rows = merge(const [], [settle(synced: true, orderId: 'o9', orderNo: '109')]);
    expect(rows.single['_syncStatus'], startsWith('Offline - synced as 109'));
  });

  test('bill reconciled at the till is listed but hidden once on the server', () {
    final kept = merge(const [], [settle(synced: true, acknowledged: true)]);
    expect(kept.single['_reconciled'], true);
    expect(kept.single['_syncStatus'], startsWith('Offline - reconciled at till'));

    final online = [
      {'_id': 'o1', 'createdAt': '2026-09-21T07:30:00.000Z'},
    ];
    final rows = merge(online, [
      settle(synced: true, acknowledged: true, orderId: 'o1'),
    ]);
    expect(rows.single['_id'], 'o1');
  });

  test('server rows are trimmed to the local day range', () {
    final inDay = DateTime(2026, 9, 21, 1, 0).toUtc().toIso8601String();
    final nextDay = DateTime(2026, 9, 22, 1, 0).toUtc().toIso8601String();
    final rows = merge([
      {'_id': 'a', 'createdAt': inDay},
      {'_id': 'b', 'createdAt': nextDay},
    ], const []);
    expect(rows.map((r) => r['_id']), ['a']);
  });

  test('bills outside the date range are dropped', () {
    final rows = merge(null, [settle(at: DateTime(2026, 9, 20, 23, 0))]);
    expect(rows, isEmpty);
  });

  test('subtotal only when the lines are the whole bill; tax never guessed', () {
    final whole = TransactionReportScreen.offlineRow(settle());
    expect(whole['food_subtotal'], 100);
    expect(whole.containsKey('tax_price'), isFalse);

    final partial = TransactionReportScreen.offlineRow(settle(cartId: 'c1'));
    expect(partial.containsKey('food_subtotal'), isFalse);
    expect(partial['_syncStatus'], contains('not yet on the server'));
  });

  test('stuck bill says why', () {
    final row = TransactionReportScreen.offlineRow(
      settle(lastError: 'No order', lastTriedAt: DateTime(2026, 9, 21)),
    );
    expect(row['_syncStatus'], startsWith('Offline - needs attention: No order'));
  });

  test('CSV carries offline lines, unit price and sync status', () {
    final csv = CsvExportService.buildCsv(merge(null, [settle()]));
    final lines = csv.trim().split('\n');
    expect(lines.first, endsWith('Payment,Sync Status'));
    final cells = lines[1].split(',');
    expect(cells[4], 'Dosa');
    expect(cells[8], '50.00'); // unit price
    expect(cells[9], '100.00'); // line total
    expect(cells[10], '100.00'); // subtotal
    expect(cells[11], ''); // tax not guessed
    expect(cells[13], '105.00');
    expect(cells.last.trim(), 'Offline - pending sync');
  });

  test('CSV shows server times in local time and menu_total as subtotal', () {
    final utc = DateTime.utc(2026, 9, 21, 20, 0);
    final csv = CsvExportService.buildCsv([
      {'_id': 'o1', 'order_no': '101', 'createdAt': utc.toIso8601String(),
       'menu_total': 90, 'tax_price': 4.5, 'total_price': 95},
    ]);
    final cells = csv.trim().split('\n')[1].split(',');
    final local = utc.toLocal();
    expect(cells[1],
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}');
    expect(cells[10], '90.00');
    expect(cells[11], '4.50');
    expect(cells.last.trim(), 'Online');
  });

  test('file name carries the report range and save time', () {
    final saved = DateTime(2026, 9, 21, 17, 43, 5);
    expect(
      CsvExportService.fileName(from, to, saved),
      'FatFox_Transactions_21-Sep-2026_saved_17-43-05.csv',
    );
    expect(
      CsvExportService.fileName(DateTime(2026, 9, 15), to, saved),
      'FatFox_Transactions_15-Sep-2026_to_21-Sep-2026_saved_17-43-05.csv',
    );
  });

  test('a folder that refuses the write yields null, not a throw', () async {
    final blocked = File('${Directory.systemTemp.path}/fatfox_csv_blocker')
      ..writeAsStringSync('x'); // a FILE where the folder should be
    final file = await CsvExportService.tryWrite(
      Directory('${blocked.path}/sub'), 'a.csv', 'x');
    expect(file, isNull);
    blocked.deleteSync();

    final ok = await CsvExportService.tryWrite(
      Directory('${Directory.systemTemp.path}/fatfox_csv_ok'), 'a.csv', 'x');
    expect(ok!.readAsStringSync(), 'x');
  });

  test('folder is shown relative to shared storage', () {
    expect(
      CsvExportService.displayFolder(
          File('/storage/emulated/0/Download/FatFox/Transactions/a.csv')),
      'Download/FatFox/Transactions',
    );
    expect(
      CsvExportService.displayFolder(File('/data/x/files/FatFox/a.csv')),
      '/data/x/files/FatFox',
    );
  });
}
