import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dineinapk/services/thermal_printer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isValidTcpPort', () {
    test('accepts the valid TCP range', () {
      expect(isValidTcpPort(1), isTrue);
      expect(isValidTcpPort(9100), isTrue);
      expect(isValidTcpPort(65535), isTrue);
    });

    test('rejects null, zero, negative, and out-of-range values', () {
      expect(isValidTcpPort(null), isFalse);
      expect(isValidTcpPort(0), isFalse);
      expect(isValidTcpPort(-1), isFalse);
      expect(isValidTcpPort(65536), isFalse);
      expect(isValidTcpPort(91000), isFalse); // the reported typo of 9100
    });
  });

  group('ReceiptPrefs.load port handling', () {
    test('keeps a valid saved port', () async {
      SharedPreferences.setMockInitialValues({'printer_port': '9100'});
      final prefs = await ReceiptPrefs.load();
      expect(prefs.bill.port, 9100);
    });

    test('falls back to 9100 for a non-numeric saved port', () async {
      SharedPreferences.setMockInitialValues({'printer_port': 'oops'});
      final prefs = await ReceiptPrefs.load();
      expect(prefs.bill.port, 9100);
    });

    test('falls back to 9100 for an out-of-range saved port', () async {
      // Reproduces the reported bug: a stray extra digit turns 9100 into
      // 91000, which used to reach Socket.connect and throw
      // "Invalid argument(s): Invalid port 91000" on every Test Print.
      SharedPreferences.setMockInitialValues({'printer_port': '91000'});
      final prefs = await ReceiptPrefs.load();
      expect(prefs.bill.port, 9100);
    });
  });
}
