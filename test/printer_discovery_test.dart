import 'package:flutter_test/flutter_test.dart';

import 'package:dineinapk/services/printer_discovery_service.dart';

void main() {
  group('ipv4SubnetPrefix', () {
    test('returns a.b.c for valid IPv4', () {
      expect(ipv4SubnetPrefix('192.168.1.42'), '192.168.1');
      expect(ipv4SubnetPrefix('10.0.0.1'), '10.0.0');
    });

    test('rejects null, empty, and non-IPv4', () {
      expect(ipv4SubnetPrefix(null), isNull);
      expect(ipv4SubnetPrefix(''), isNull);
      expect(ipv4SubnetPrefix('not-an-ip'), isNull);
      expect(ipv4SubnetPrefix('192.168.1'), isNull);
      expect(ipv4SubnetPrefix('192.168.1.256'), isNull);
    });
  });

  group('DiscoveredPrinter.id', () {
    test('is stable per transport', () {
      expect(
        const DiscoveredPrinter(
          transport: PrinterTransport.lan,
          displayName: 'x',
          host: '192.168.1.10',
          port: 9100,
        ).id,
        'lan:192.168.1.10:9100',
      );
      expect(
        const DiscoveredPrinter(
          transport: PrinterTransport.bluetooth,
          displayName: 'Kitchen',
          macAddress: 'AA:BB:CC:DD:EE:FF',
        ).id,
        'bt:AA:BB:CC:DD:EE:FF',
      );
    });
  });
}
