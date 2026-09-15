import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:dineinapk/services/thermal_printer_service.dart';
import 'package:dineinapk/models/table_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = ThermalPrinterService();

  test('KOT header row has a real space gap between item name and quantity', () async {
    final bytes = await service.generateKotBytes(
      table: DineInTable(
        id: 't1',
        tableNumber: '10',
        areaId: 'a1',
        noOfPeople: 2,
        tableStatus: 'BLANK',
        status: 'BLANK',
        totalPrice: 0,
        itemCount: 0,
      ),
      items: const [],
      restaurantName: 'THE FAT FOX',
      paperSize: PaperSize.mm58,
    );
    // generator.text() encodes its payload as one contiguous Latin-1 run,
    // so decoding the whole stream and searching for a literal substring is
    // safe even though it also contains ESC/POS control bytes elsewhere.
    final text = latin1.decode(bytes, allowInvalid: true);

    // Before the fix (Generator.row()'s absolute-positioning bytes not
    // honored by many Bluetooth printers): columns printed back-to-back
    // with zero gap. Guard against that regression directly.
    expect(text, isNot(contains('Item NameQty')));
    // After the fix: a real, multi-space gap padded to the column width.
    expect(text, matches(RegExp('Item Name {5,}Qty')));
  });

  test('Bill row right-aligns the amount with a real space gap, not glued text', () async {
    final bill = BillPrintData(
      restaurantName: 'THE FAT FOX',
      tableNumber: '10',
      lines: const [BillLine(name: 'Tea', quantity: 1, lineTotal: 20.0)],
      subTotal: 20.0,
      taxTotal: 1.0,
      grandTotal: 21.0,
    );
    final bytes = await service.generateBillBytes(bill: bill, paperSize: PaperSize.mm80);
    final text = latin1.decode(bytes, allowInvalid: true);

    expect(text, isNot(contains('TeaRs. 20.00')));
    expect(text, matches(RegExp('Tea {5,}1 {5,}Rs\\. 20\\.00')));
  });

  test('_amountRow (Subtotal/Grand Total) keeps a real gap before the amount', () async {
    final bill = BillPrintData(
      restaurantName: 'THE FAT FOX',
      tableNumber: '10',
      lines: const [BillLine(name: 'Tea', quantity: 1, lineTotal: 20.0)],
      subTotal: 20.0,
      taxTotal: 1.0,
      grandTotal: 21.0,
    );
    final bytes = await service.generateBillBytes(bill: bill, paperSize: PaperSize.mm80);
    final text = latin1.decode(bytes, allowInvalid: true);

    expect(text, isNot(contains('SubtotalRs. 20.00')));
    expect(text, matches(RegExp('Subtotal {5,}Rs\\. 20\\.00')));
    expect(text, isNot(contains('GRAND TOTALRs. 21.00')));
    expect(text, matches(RegExp('GRAND TOTAL {2,}Rs\\. 21\\.00')));
  });
}
