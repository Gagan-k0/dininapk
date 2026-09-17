import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dineinapk/services/thermal_printer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ReceiptPrefs keeps the loaded printer config in a static field, so without
  // this every test after the first reads the FIRST test's printers.
  setUp(ReceiptPrefs.invalidateCache);

  group('KOT / Bill printer assignment', () {
    test('an existing single-printer setup keeps printing KOTs on that printer', () async {
      SharedPreferences.setMockInitialValues({
        'printer_type': 'LAN',
        'printer_ip': '192.168.1.50',
      });
      final prefs = await ReceiptPrefs.load();
      expect(prefs.kotSameAsBill, isTrue);
      expect(prefs.targetFor(PrinterRole.kot).ip, '192.168.1.50');
      expect(prefs.targetFor(PrinterRole.bill).ip, '192.168.1.50');
    });

    test('a separate KOT printer receives KOTs only', () async {
      SharedPreferences.setMockInitialValues({
        'printer_type': 'LAN',
        'printer_ip': '192.168.1.50',
        'kot_printer_same_as_bill': false,
        'kot_printer_type': 'Bluetooth',
        'kot_printer_bt_mac': '66:02:BD:06:18:7B',
      });
      final prefs = await ReceiptPrefs.load();
      expect(prefs.targetFor(PrinterRole.kot).isBluetooth, isTrue);
      expect(prefs.targetFor(PrinterRole.kot).btMac, '66:02:BD:06:18:7B');
      expect(prefs.targetFor(PrinterRole.bill).ip, '192.168.1.50');
    });

    test('an unset separate KOT printer refuses instead of using the bill printer', () async {
      SharedPreferences.setMockInitialValues({
        'printer_ip': '192.168.1.50',
        'kot_printer_same_as_bill': false,
      });
      await expectLater(
        ThermalPrinterService().printBytes(const [0x0A], role: PrinterRole.kot),
        throwsA(predicate((e) => e.toString().contains('KOT printer'))),
      );
    });
  });

  test('switching between two Bluetooth printers reconnects to the right one', () async {
    const channel = MethodChannel('groons.web.app/print');
    final connects = <String>[];
    var disconnects = 0;
    var linkOpen = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'connectionstatus':
          return linkOpen;
        case 'connect':
          connects.add(call.arguments as String);
          linkOpen = true;
          return true;
        case 'disconnect':
          disconnects++;
          linkOpen = false;
          return true;
        case 'writebytes':
          return true;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    SharedPreferences.setMockInitialValues({
      'printer_type': 'Bluetooth',
      'printer_bt_mac': 'AA:AA:AA:AA:AA:AA',
      'kot_printer_same_as_bill': false,
      'kot_printer_type': 'Bluetooth',
      'kot_printer_bt_mac': 'BB:BB:BB:BB:BB:BB',
    });
    final service = ThermalPrinterService();

    await service.printBytes(const [0x0A]);
    await service.printBytes(const [0x0A], role: PrinterRole.kot);
    await service.printBytes(const [0x0A], role: PrinterRole.kot);

    // The KOT must not ride the bill printer's open link, and a repeat KOT
    // must reuse its own link instead of reconnecting.
    expect(connects, ['AA:AA:AA:AA:AA:AA', 'BB:BB:BB:BB:BB:BB']);
    expect(disconnects, 1);
  });
}
