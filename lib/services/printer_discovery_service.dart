import 'dart:async';
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'thermal_printer_service.dart' show isValidTcpPort;
import 'usb_printer.dart';

/// How the waiter tablet reaches a silent ESC/POS printer.
enum PrinterTransport { lan, bluetooth, usb }

/// One candidate found by LAN :9100 probe, Bluetooth paired list or USB host.
class DiscoveredPrinter {
  final PrinterTransport transport;
  final String displayName;
  final String? host;
  final int port;
  final String? macAddress;

  /// `vendorId:productId` of a USB printer.
  final String? usbId;

  const DiscoveredPrinter({
    required this.transport,
    required this.displayName,
    this.host,
    this.port = 9100,
    this.macAddress,
    this.usbId,
  });

  String get id => switch (transport) {
        PrinterTransport.lan => 'lan:${host!}:$port',
        PrinterTransport.bluetooth => 'bt:${macAddress!}',
        PrinterTransport.usb => 'usb:${usbId!}',
      };
}

/// Derives `a.b.c` from an IPv4 string, or null if invalid / not IPv4.
String? ipv4SubnetPrefix(String? ip) {
  if (ip == null || ip.isEmpty) return null;
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
  }
  return '${parts[0]}.${parts[1]}.${parts[2]}';
}

/// Silent thermal discovery — no Android PrintManager / system dialog.
class PrinterDiscoveryService {
  final NetworkInfo _networkInfo;

  PrinterDiscoveryService({NetworkInfo? networkInfo})
      : _networkInfo = networkInfo ?? NetworkInfo();

  /// Probe the tablet's /24 subnet for hosts accepting TCP [port] (default 9100).
  Future<List<DiscoveredPrinter>> scanLan({
    int port = 9100,
    Duration timeout = const Duration(milliseconds: 350),
    int concurrency = 40,
    void Function(int checked, int total)? onProgress,
  }) async {
    if (!isValidTcpPort(port)) {
      throw ArgumentError.value(port, 'port', 'Must be 1-65535');
    }
    final wifiIp = await _networkInfo.getWifiIP();
    var prefix = ipv4SubnetPrefix(wifiIp);

    if (prefix == null) {
      for (final ni in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      )) {
        for (final addr in ni.addresses) {
          if (addr.isLoopback) continue;
          prefix = ipv4SubnetPrefix(addr.address);
          if (prefix != null) break;
        }
        if (prefix != null) break;
      }
    }

    if (prefix == null) {
      throw Exception(
        'Cannot determine Wi‑Fi subnet. Connect the tablet to LAN Wi‑Fi.',
      );
    }

    final selfHost = wifiIp;
    final found = <DiscoveredPrinter>[];
    const total = 254;
    var checked = 0;

    Future<void> probe(int hostOctet) async {
      final host = '$prefix.$hostOctet';
      if (host == selfHost) {
        checked++;
        onProgress?.call(checked, total);
        return;
      }
      try {
        final socket = await Socket.connect(host, port, timeout: timeout);
        await socket.close();
        found.add(
          DiscoveredPrinter(
            transport: PrinterTransport.lan,
            displayName: '$host:$port',
            host: host,
            port: port,
          ),
        );
      } catch (_) {
        // closed / refused / timeout — not a raw ESC/POS listener
      } finally {
        checked++;
        onProgress?.call(checked, total);
      }
    }

    final octets = List<int>.generate(254, (i) => i + 1);
    for (var i = 0; i < octets.length; i += concurrency) {
      final chunk = octets.skip(i).take(concurrency);
      await Future.wait(chunk.map(probe));
    }

    found.sort((a, b) => a.displayName.compareTo(b.displayName));
    return found;
  }

  /// Lists paired Bluetooth devices (classic SPP printers show up after pairing
  /// in Android Settings). Requests nearby/Bluetooth permissions when needed.
  Future<List<DiscoveredPrinter>> scanBluetooth() async {
    await _ensureBluetoothPermissions();

    final enabled = await PrintBluetoothThermal.bluetoothEnabled;
    if (!enabled) {
      throw Exception('Turn on Bluetooth, then try Scan again.');
    }

    final granted = await PrintBluetoothThermal.isPermissionBluetoothGranted;
    if (!granted) {
      throw Exception(
        'Bluetooth permission denied. Allow Nearby devices / Bluetooth for FatFox Waiter.',
      );
    }

    final paired = await PrintBluetoothThermal.pairedBluetooths;
    final list = paired
        .where((b) => b.macAdress.trim().isNotEmpty)
        .map(
          (b) => DiscoveredPrinter(
            transport: PrinterTransport.bluetooth,
            displayName: b.name.trim().isEmpty ? b.macAdress : b.name.trim(),
            macAddress: b.macAdress.trim(),
          ),
        )
        .toList();
    list.sort((a, b) => a.displayName.compareTo(b.displayName));
    return list;
  }

  /// Printers plugged into the tablet over USB / OTG. No permission prompt
  /// here — Android asks once, on the first print to that device.
  Future<List<DiscoveredPrinter>> scanUsb() async {
    final printers = await UsbPrinter.list();
    return printers
        .map(
          (p) => DiscoveredPrinter(
            transport: PrinterTransport.usb,
            displayName: p.name,
            usbId: p.id,
          ),
        )
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
  }

  Future<void> _ensureBluetoothPermissions() async {
    if (!Platform.isAndroid) return;

    final statuses = await [
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.locationWhenInUse,
    ].request();

    final scanOk =
        statuses[Permission.bluetoothScan]?.isGranted == true ||
        statuses[Permission.bluetooth]?.isGranted == true;
    final connectOk =
        statuses[Permission.bluetoothConnect]?.isGranted == true ||
        statuses[Permission.bluetooth]?.isGranted == true;

    // Pre-Android-12 often needs location for BT discovery of unpaired devices;
    // we only list paired devices, but requesting avoids OEM blocks.
    if (!scanOk || !connectOk) {
      throw Exception(
        'Bluetooth permission required to list printers. Enable it in App settings.',
      );
    }
  }
}
