import 'dart:convert';

import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dineinapk/models/receipt_customization.dart';
import 'package:dineinapk/models/table_model.dart';
import 'package:dineinapk/services/receipt_customization_service.dart';
import 'package:dineinapk/services/thermal_printer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReceiptCustomization JSON round-trip', () {
    test('fromJson fills missing keys with admin-matching defaults', () {
      final c = ReceiptCustomization.fromJson({'showRestaurantGstin': false});
      expect(c.showRestaurantGstin, isFalse);
      expect(c.showRestaurantName, isTrue); // default, not in the payload
      expect(c.billFontSize, 'medium');
    });

    test('toJson -> fromJson preserves every edited field', () {
      final edited = ReceiptCustomization.defaults.copyWith(
        showRestaurantGstin: false,
        restaurantNameAlignment: 'left',
        kotShowAddons: false,
        billShowSerialNumber: false,
        footerThankYouMessage: 'Come again!',
      );
      final roundTripped = ReceiptCustomization.fromJson(
        jsonDecode(jsonEncode(edited.toJson())) as Map<String, dynamic>,
      );
      expect(roundTripped.showRestaurantGstin, isFalse);
      expect(roundTripped.restaurantNameAlignment, 'left');
      expect(roundTripped.kotShowAddons, isFalse);
      expect(roundTripped.billShowSerialNumber, isFalse);
      expect(roundTripped.footerThankYouMessage, 'Come again!');
    });

    test('a field only the exe/website use round-trips unread', () {
      // fontFamily/padding/contentOffsetX/baseFontSize are meaningless to raw
      // ESC/POS text printing but must never be silently dropped, or editing
      // on the waiter app would corrupt values the exe/website rely on.
      final json = ReceiptCustomization.fromJson({
        'fontFamily': 'Courier New',
        'paddingLeft': 4,
        'contentOffsetX': -2,
        'baseFontSize': 16,
      }).toJson();
      expect(json['fontFamily'], 'Courier New');
      expect(json['paddingLeft'], 4);
      expect(json['contentOffsetX'], -2);
      expect(json['baseFontSize'], 16);
    });
  });

  group('ThermalPrinterService respects receipt customization toggles', () {
    final service = ThermalPrinterService();
    final table = DineInTable(
      id: 't1',
      tableNumber: '10',
      areaId: 'a1',
      noOfPeople: 2,
      tableStatus: 'BLANK',
      status: 'BLANK',
      totalPrice: 0,
      itemCount: 0,
    );

    test('kotShowDate=false omits the Date line from KOT bytes', () async {
      final withDate = await service.generateKotBytes(
        table: table,
        items: const [],
        restaurantName: 'THE FAT FOX',
      );
      final withoutDate = await service.generateKotBytes(
        table: table,
        items: const [],
        restaurantName: 'THE FAT FOX',
        customization: ReceiptCustomization.defaults.copyWith(kotShowDate: false),
      );
      expect(latin1.decode(withDate, allowInvalid: true), contains('Date:'));
      expect(latin1.decode(withoutDate, allowInvalid: true), isNot(contains('Date:')));
    });

    test('showRestaurantGstin=false omits GSTIN from the bill', () async {
      final bill = BillPrintData(
        restaurantName: 'THE FAT FOX',
        gstin: '27AABCU9603R1ZP',
        tableNumber: '10',
        lines: const [BillLine(name: 'Paneer Tikka', quantity: 1, lineTotal: 120)],
        subTotal: 120,
        taxTotal: 0,
        grandTotal: 120,
      );
      final shown = await service.generateBillBytes(bill: bill);
      final hidden = await service.generateBillBytes(
        bill: bill,
        customization: ReceiptCustomization.defaults.copyWith(showRestaurantGstin: false),
      );
      expect(latin1.decode(shown, allowInvalid: true), contains('GSTIN'));
      expect(latin1.decode(hidden, allowInvalid: true), isNot(contains('GSTIN')));
    });

    test('billShowCustomerCopy labels ONE bill (admin parity), never prints it twice', () async {
      final bill = BillPrintData(
        restaurantName: 'THE FAT FOX',
        tableNumber: '10',
        paymentMode: 'upi_qr',
        lines: const [BillLine(name: 'Paneer Tikka', quantity: 1, lineTotal: 120)],
        subTotal: 120,
        taxTotal: 0,
        grandTotal: 120,
      );
      final off = latin1.decode(await service.generateBillBytes(
        bill: bill,
        customization: ReceiptCustomization.defaults.copyWith(billShowCustomerCopy: false),
      ), allowInvalid: true);
      final on = latin1.decode(await service.generateBillBytes(
        bill: bill,
        customization: ReceiptCustomization.defaults.copyWith(billShowCustomerCopy: true),
      ), allowInvalid: true);
      expect('Paneer Tikka'.allMatches(on).length, 1);
      expect(on, contains('CUSTOMER COPY'));
      expect(off, isNot(contains('CUSTOMER COPY')));
      expect(on, contains('Payment : UPI QR'));
    });

    test('KOT has no restaurant header and its title fits double-width on 58mm', () async {
      final text = latin1.decode(await service.generateKotBytes(
        table: table,
        items: const [],
        restaurantName: 'THE FAT FOX',
        paperSize: PaperSize.mm58,
        customization: ReceiptCustomization.defaults.copyWith(customHeaderLine1: 'HDR1'),
      ), allowInvalid: true);
      expect(text, isNot(contains('THE FAT FOX')));
      expect(text, isNot(contains('HDR1')));
      expect(text, isNot(contains('KITCHEN ORDER TICKET')));
      expect(text, contains('KOT'));
    });

    test('non-Latin1 currencySymbol from the server does not crash printing', () async {
      final bill = BillPrintData(
        restaurantName: 'THE FAT FOX',
        tableNumber: '10',
        lines: const [BillLine(name: 'Paneer Tikka', quantity: 1, lineTotal: 120)],
        subTotal: 120,
        taxTotal: 0,
        grandTotal: 120,
      );
      final bytes = await service.generateBillBytes(
        bill: bill,
        customization: ReceiptCustomization.defaults.copyWith(currencySymbol: '₹'),
      );
      expect(bytes, isNotEmpty);
    });
  });

  group('ReceiptCustomizationService offline caching', () {
    test('loadCached returns admin-matching defaults before any sync', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ReceiptCustomizationService();
      final loaded = await service.loadCached();
      expect(loaded.showRestaurantName, ReceiptCustomization.defaults.showRestaurantName);
    });

    test('saveLocal then loadCached round-trips without any network call', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ReceiptCustomizationService();
      final edited = ReceiptCustomization.defaults.copyWith(showRestaurantGstin: false);
      await service.saveLocal(edited);
      final loaded = await service.loadCached();
      expect(loaded.showRestaurantGstin, isFalse);
    });
  });
}
