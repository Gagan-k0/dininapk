import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dineinapk/services/printer_discovery_service.dart';
import 'package:dineinapk/services/thermal_printer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.fatfox.dinein/usb_printer');
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'list':
          return [
            {'vendorId': 1155, 'productId': 22304, 'name': 'POS-80'},
            {'vendorId': 1659, 'productId': 8965, 'name': ''},
          ];
        case 'write':
          return true;
      }
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));

  test('USB scan lists attached printers with a stable vendor:product id', () async {
    final found = await PrinterDiscoveryService().scanUsb();
    expect(found.map((p) => p.displayName), ['POS-80', 'USB printer 067B:2305']);
    expect(found.first.usbId, '1155:22304');
    expect(found.first.transport, PrinterTransport.usb);
  });

  test('a USB bill printer receives the job over the USB channel', () async {
    SharedPreferences.setMockInitialValues({
      'printer_type': 'USB',
      'printer_usb_id': '1155:22304',
    });
    await ThermalPrinterService().printBytes(const [0x1B, 0x40]);

    final write = calls.singleWhere((c) => c.method == 'write');
    final args = write.arguments as Map;
    expect(args['vendorId'], 1155);
    expect(args['productId'], 22304);
    expect(args['bytes'], [0x1B, 0x40]);
  });

  test('a separate KOT printer can be USB while bills go elsewhere', () async {
    SharedPreferences.setMockInitialValues({
      'printer_type': 'Bluetooth',
      'printer_bt_mac': 'AA:AA:AA:AA:AA:AA',
      'kot_printer_same_as_bill': false,
      'kot_printer_type': 'USB',
      'kot_printer_usb_id': '1659:8965',
    });
    await ThermalPrinterService().printBytes(const [0x0A], role: PrinterRole.kot);
    expect((calls.single.arguments as Map)['vendorId'], 1659);
  });

  test('USB selected but no printer picked refuses with a clear message', () async {
    SharedPreferences.setMockInitialValues({'printer_type': 'USB'});
    await expectLater(
      ThermalPrinterService().printBytes(const [0x0A]),
      throwsA(predicate((e) => e.toString().contains('USB printer not selected'))),
    );
    expect(calls, isEmpty);
  });
}
