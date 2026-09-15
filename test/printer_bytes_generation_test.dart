import 'package:flutter_test/flutter_test.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:dineinapk/services/thermal_printer_service.dart';
import 'package:dineinapk/models/table_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ThermalPrinterService();

  test('generateTestBytes succeeds for 80mm and 58mm (no ArgumentError)', () async {
    expect(
      (await service.generateTestBytes(paperSize: PaperSize.mm80)).isNotEmpty,
      isTrue,
    );
    expect(
      (await service.generateTestBytes(paperSize: PaperSize.mm58)).isNotEmpty,
      isTrue,
    );
  });

  test('generateTestBytes with a header containing a rupee sign / emoji does not throw',
      () async {
    final bytes = await service.generateTestBytes(header: 'FAT FOX ₹ 🍕');
    expect(bytes, isNotEmpty);
  });

  test('generateKotBytes succeeds (date line no longer uses a bullet)', () async {
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
    );
    expect(bytes, isNotEmpty);
  });

  test('generateBillBytes succeeds with real amounts (rupee sign no longer breaks it)',
      () async {
    final bill = BillPrintData(
      restaurantName: 'THE FAT FOX',
      tableNumber: '10',
      lines: const [BillLine(name: 'Paneer Tikka', quantity: 2, lineTotal: 240.0)],
      subTotal: 240.0,
      discount: 10,
      discountName: 'Loyalty',
      taxTotal: 12.0,
      grandTotal: 242.0,
    );
    final bytes = await service.generateBillBytes(bill: bill);
    expect(bytes, isNotEmpty);
  });

  test('generateBillBytes with a non-Latin1 tax breakdown label does not throw', () async {
    // Tax names are restaurant-admin-configured server data — a stray
    // non-ASCII character there must not crash every bill for that tenant.
    final bill = BillPrintData(
      restaurantName: 'THE FAT FOX',
      tableNumber: '10',
      lines: const [BillLine(name: 'Paneer Tikka', quantity: 2, lineTotal: 240.0)],
      subTotal: 240.0,
      taxBreakdown: const [MapEntry('CGST — 2.5%', 6.0), MapEntry('SGST • 2.5%', 6.0)],
      taxTotal: 12.0,
      grandTotal: 252.0,
    );
    final bytes = await service.generateBillBytes(bill: bill);
    expect(bytes, isNotEmpty);
  });
}
