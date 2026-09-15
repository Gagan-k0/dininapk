import 'package:flutter/services.dart';

/// Raw ESC/POS over Android USB host (OTG). Native side: MainActivity.kt.
class UsbPrinter {
  static const MethodChannel _channel = MethodChannel('com.fatfox.dinein/usb_printer');

  final int vendorId;
  final int productId;
  final String name;

  const UsbPrinter({required this.vendorId, required this.productId, required this.name});

  /// `vendorId:productId` — stable across re-plugs, unlike the
  /// /dev/bus/usb path Android assigns each time the cable goes in.
  String get id => '$vendorId:$productId';

  static (int, int)? parseId(String id) {
    final parts = id.split(':');
    if (parts.length != 2) return null;
    final vendor = int.tryParse(parts[0]);
    final product = int.tryParse(parts[1]);
    if (vendor == null || product == null) return null;
    return (vendor, product);
  }

  static String _hex(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();

  /// Attached devices exposing a bulk-OUT endpoint (printer class or the
  /// vendor-specific class most cheap thermal printers report).
  static Future<List<UsbPrinter>> list() async {
    try {
      final raw = await _channel.invokeListMethod<Map>('list') ?? const [];
      return raw.map((m) {
        final vendor = m['vendorId'] as int;
        final product = m['productId'] as int;
        final name = (m['name'] as String?)?.trim() ?? '';
        return UsbPrinter(
          vendorId: vendor,
          productId: product,
          name: name.isEmpty ? 'USB printer ${_hex(vendor)}:${_hex(product)}' : name,
        );
      }).toList();
    } on MissingPluginException {
      throw Exception('USB printers are supported on Android only.');
    }
  }

  /// Android shows its USB permission dialog on first use; the write fails
  /// with that refusal message if the waiter taps Cancel.
  static Future<void> write(String id, List<int> bytes) async {
    final parsed = parseId(id);
    if (parsed == null) {
      throw Exception('USB printer not selected. Open Printer Settings → Scan.');
    }
    try {
      // Bounded so a permission dialog dismissed without an answer can't
      // leave the POS "Printing…" forever.
      await _channel.invokeMethod('write', {
        'vendorId': parsed.$1,
        'productId': parsed.$2,
        'bytes': Uint8List.fromList(bytes),
      }).timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw Exception('USB printer did not respond. Replug it and try again.'),
      );
    } on PlatformException catch (e) {
      throw Exception(e.message ?? 'USB printer failed to accept the print job.');
    } on MissingPluginException {
      throw Exception('USB printers are supported on Android only.');
    }
  }
}
