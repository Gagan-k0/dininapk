import 'dart:io';

import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:intl/intl.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/table_model.dart';
import '../models/cart_model.dart';

/// Lowest/highest values `Socket.connect` accepts — anything outside this
/// throws `ArgumentError: Invalid argument(s): Invalid port <n>` instead of
/// a friendly message, so every reader/writer of a printer port must clamp
/// to this range first.
const int kMinTcpPort = 1;
const int kMaxTcpPort = 65535;

bool isValidTcpPort(int? port) =>
    port != null && port >= kMinTcpPort && port <= kMaxTcpPort;

/// Device-local receipt preferences (admin keeps receipt customization in
/// localStorage per till too — it is not server data a waiter can read).
class ReceiptPrefs {
  final String header;
  final PaperSize paperSize;

  /// `LAN` or `Bluetooth` (USB reserved / not wired yet).
  final String printerType;
  final String printerIp;
  final int printerPort;
  final String bluetoothMac;
  final String bluetoothName;

  /// Admin POS rule: allow "Release" at KOT_PRINT/RUNNING without a printed bill.
  final bool kotEnableReleaseTable;

  const ReceiptPrefs({
    required this.header,
    required this.paperSize,
    required this.printerType,
    required this.printerIp,
    required this.printerPort,
    required this.bluetoothMac,
    required this.bluetoothName,
    required this.kotEnableReleaseTable,
  });

  bool get isBluetooth =>
      printerType.toLowerCase() == 'bluetooth';

  bool get printerConfigured =>
      isBluetooth ? bluetoothMac.isNotEmpty : printerIp.isNotEmpty;

  static Future<ReceiptPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    final paper = prefs.getString('printer_paper') ?? '80mm';
    final savedPort = int.tryParse(prefs.getString('printer_port') ?? '9100');
    return ReceiptPrefs(
      header: prefs.getString('printer_header') ?? 'THE FAT FOX',
      paperSize: paper.contains('58') ? PaperSize.mm58 : PaperSize.mm80,
      printerType: prefs.getString('printer_type') ?? 'LAN',
      printerIp: prefs.getString('printer_ip') ?? '',
      // A bad value already saved (pre-dating validation, or hand-edited)
      // must not throw ArgumentError on every future print — fall back.
      printerPort: isValidTcpPort(savedPort) ? savedPort! : 9100,
      bluetoothMac: prefs.getString('printer_bt_mac') ?? '',
      bluetoothName: prefs.getString('printer_bt_name') ?? '',
      kotEnableReleaseTable: prefs.getBool('kot_enable_release_table') ?? false,
    );
  }
}

/// One printed bill line.
class BillLine {
  final String name;
  final String? variant;
  final List<String> addons;
  final String? note;
  final int quantity;
  final double lineTotal;
  final bool cancelled;

  const BillLine({
    required this.name,
    this.variant,
    this.addons = const [],
    this.note,
    required this.quantity,
    required this.lineTotal,
    this.cancelled = false,
  });
}

/// Everything the customer bill shows (mirrors admin print-dinein-save).
class BillPrintData {
  final String restaurantName;
  final String? address;
  final String? phone;
  final String? gstin;
  final String tableNumber;
  final String? paymentMode;
  final String? customerName;
  final String? customerMobile;
  final List<BillLine> lines;
  final double subTotal; // food_subtotal (pre-surge)
  final double discount;
  final String? discountName;
  final double containerCharge;
  final double areaCharge;
  final String? areaChargeLabel;
  final List<MapEntry<String, double>> taxBreakdown; // e.g. CGST (2.5%) → 10.95
  final double taxTotal;
  final double roundOff;
  final double grandTotal;
  final String? footer;

  const BillPrintData({
    required this.restaurantName,
    this.address,
    this.phone,
    this.gstin,
    required this.tableNumber,
    this.paymentMode,
    this.customerName,
    this.customerMobile,
    required this.lines,
    required this.subTotal,
    this.discount = 0,
    this.discountName,
    this.containerCharge = 0,
    this.areaCharge = 0,
    this.areaChargeLabel,
    this.taxBreakdown = const [],
    required this.taxTotal,
    this.roundOff = 0,
    required this.grandTotal,
    this.footer,
  });
}

class ThermalPrinterService {
  // Raw ESC/POS printers render Latin-1 (ISO-8859-1) only — ₹ (U+20B9) isn't
  // in that range and the generator throws ArgumentError on it, unlike the
  // admin panel's receipts, which are printed as HTML/CSS and can show any
  // Unicode glyph. "Rs." is the standard ASCII-safe stand-in on thermal bills.
  final NumberFormat _currencyFormat = NumberFormat.currency(
    symbol: 'Rs. ',
    decimalDigits: 2,
  );
  final DateFormat _dateFormat = DateFormat('dd MMM yyyy - h:mm a');

  /// Routes free text (menu items, customer names, the user-typed header)
  /// through Latin-1 safety: normalizes common punctuation the printer's
  /// font can't render, then replaces anything still outside Latin-1 so a
  /// stray character (an emoji in an item name, a pasted "₹") can never
  /// throw ArgumentError deep inside the ESC/POS generator.
  String _safe(String s) {
    final normalized = s
        .replaceAll('₹', 'Rs. ')
        .replaceAll(RegExp('[‒-―]'), '-') // figure/en/em dash
        .replaceAll('•', '-') // •
        .replaceAll(RegExp('[‘’]'), "'")
        .replaceAll(RegExp('[“”]'), '"');
    return String.fromCharCodes(
      normalized.codeUnits.map((c) => c <= 0xFF ? c : 0x3F), // '?'
    );
  }

  Future<void> sendRaw(
    List<int> bytes, {
    required String host,
    required int port,
  }) async {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    try {
      socket.add(bytes);
      await socket.flush();
    } finally {
      await socket.close();
    }
  }

  /// Silent ESC/POS — LAN TCP :9100 or Bluetooth SPP. Never uses PrintManager.
  Future<void> printBytes(List<int> bytes) async {
    final prefs = await ReceiptPrefs.load();
    if (!prefs.printerConfigured) {
      throw Exception(
        prefs.isBluetooth
            ? 'Bluetooth printer not selected. Open Printer Settings → Scan.'
            : 'Printer IP not configured. Open Printer Settings → Scan or enter IP.',
      );
    }
    if (prefs.isBluetooth) {
      await _sendBluetooth(bytes, mac: prefs.bluetoothMac);
      return;
    }
    await sendRaw(bytes, host: prefs.printerIp, port: prefs.printerPort);
  }

  Future<void> _sendBluetooth(List<int> bytes, {required String mac}) async {
    final connected = await PrintBluetoothThermal.connectionStatus;
    if (!connected) {
      final ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
      if (!ok) {
        throw Exception(
          'Could not connect to Bluetooth printer $mac. Pair it in Android Settings first.',
        );
      }
    }
    final written = await PrintBluetoothThermal.writeBytes(bytes);
    if (!written) {
      throw Exception('Bluetooth printer failed to accept the print job.');
    }
  }

  Future<List<int>> generateTestBytes({
    String header = 'THE FAT FOX',
    PaperSize paperSize = PaperSize.mm80,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    List<int> bytes = [];

    bytes += generator.text(
      _safe(header),
      styles: const PosStyles(
        align: PosAlign.center,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
        bold: true,
      ),
    );
    bytes += generator.text(
      'TEST PRINT',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.text(
      'Silent thermal printer ready',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.text(
      'Date: ${_dateFormat.format(DateTime.now())}',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.hr();
    bytes += generator.text(
      'ESC/POS - no system print dialog',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }

  // Generate KOT Byte Stream for 58mm / 80mm ESC/POS Printers
  Future<List<int>> generateKotBytes({
    required DineInTable table,
    required List<CartLineItem> items,
    required String restaurantName,
    PaperSize paperSize = PaperSize.mm80,
    String? department,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    List<int> bytes = [];

    bytes += generator.text(
      'KITCHEN ORDER TICKET (KOT)',
      styles: const PosStyles(
        align: PosAlign.center,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
        bold: true,
      ),
    );

    bytes += generator.text(
      _safe(restaurantName),
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    if (department != null && department.isNotEmpty) {
      bytes += generator.text(
        _safe('DEPARTMENT : $department'),
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
    }

    bytes += generator.feed(1);
    bytes += generator.text(
      _safe('Table #: ${table.tableNumber}'),
      styles: const PosStyles(bold: true, height: PosTextSize.size2),
    );
    bytes += generator.text('Date: ${_dateFormat.format(DateTime.now())}');
    bytes += generator.hr();

    bytes += generator.row([
      PosColumn(
        text: 'Item Name',
        width: 8,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: 'Qty',
        width: 4,
        styles: const PosStyles(bold: true, align: PosAlign.right),
      ),
    ]);
    bytes += generator.hr();

    for (var line in items) {
      String name = line.item.name;
      if (line.selectedVariant != null) {
        name += ' (${line.selectedVariant!.name})';
      }
      if (line.cancelStatus == 1) name += ' (cancelled)';
      bytes += generator.row([
        PosColumn(text: _safe(name), width: 9),
        PosColumn(
          text: 'x${line.quantity}',
          width: 3,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      for (final addon in line.selectedAddons) {
        bytes += generator.text(_safe(
            '   + ${addon.valueName.isNotEmpty ? addon.valueName : addon.name}'));
      }
      if (line.instruction != null && line.instruction!.isNotEmpty) {
        bytes += generator.text(_safe('   Note: ${line.instruction}'));
      }
    }

    bytes += generator.hr();
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }

  /// Customer bill — same rows as the admin printed bill: items at BASE price,
  /// then Subtotal → Discount → Container → AC/Area charge → tax rows →
  /// Round Off → Grand Total.
  Future<List<int>> generateBillBytes({
    required BillPrintData bill,
    PaperSize paperSize = PaperSize.mm80,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    List<int> bytes = [];

    bytes += generator.text(
      _safe(bill.restaurantName),
      styles: const PosStyles(
        align: PosAlign.center,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
        bold: true,
      ),
    );
    if (bill.address != null && bill.address!.isNotEmpty) {
      bytes += generator.text(_safe(bill.address!), styles: const PosStyles(align: PosAlign.center));
    }
    if (bill.phone != null && bill.phone!.isNotEmpty) {
      bytes += generator.text(_safe('Ph: ${bill.phone}'), styles: const PosStyles(align: PosAlign.center));
    }
    if (bill.gstin != null && bill.gstin!.isNotEmpty) {
      bytes += generator.text(_safe('GSTIN: ${bill.gstin}'), styles: const PosStyles(align: PosAlign.center));
    }
    bytes += generator.hr();
    bytes += generator.text('Date: ${_dateFormat.format(DateTime.now())}');
    bytes += generator.text(
      _safe('Table No : ${bill.tableNumber}'),
      styles: const PosStyles(bold: true),
    );
    if (bill.paymentMode != null && bill.paymentMode!.isNotEmpty) {
      bytes += generator.text(_safe('Payment : ${bill.paymentMode}'));
    }
    if (bill.customerName != null && bill.customerName!.isNotEmpty) {
      bytes += generator.text(_safe('Name : ${bill.customerName}'));
    }
    if (bill.customerMobile != null && bill.customerMobile!.isNotEmpty) {
      bytes += generator.text(_safe('Mobile : ${bill.customerMobile}'));
    }
    bytes += generator.hr();

    bytes += generator.row([
      PosColumn(text: 'Item', width: 6, styles: const PosStyles(bold: true)),
      PosColumn(
        text: 'Qty',
        width: 2,
        styles: const PosStyles(bold: true, align: PosAlign.center),
      ),
      PosColumn(
        text: 'Amount',
        width: 4,
        styles: const PosStyles(bold: true, align: PosAlign.right),
      ),
    ]);
    bytes += generator.hr();

    for (final line in bill.lines) {
      var name = line.name;
      if (line.variant != null && line.variant!.isNotEmpty) name += ' (${line.variant})';
      if (line.cancelled) name += ' (cancelled)';
      bytes += generator.row([
        PosColumn(text: _safe(name), width: 6),
        PosColumn(
          text: '${line.quantity}',
          width: 2,
          styles: const PosStyles(align: PosAlign.center),
        ),
        PosColumn(
          text: _currencyFormat.format(line.lineTotal),
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);
      for (final a in line.addons) {
        bytes += generator.text(_safe('   + $a'));
      }
      if (line.note != null && line.note!.isNotEmpty) {
        bytes += generator.text(_safe('   (${line.note})'));
      }
    }

    bytes += generator.hr();
    bytes += _amountRow(generator, 'Subtotal', bill.subTotal, bold: true);
    if (bill.discount > 0) {
      final label = bill.discountName == null || bill.discountName!.isEmpty
          ? 'Discount'
          : 'Discount (${bill.discountName})';
      bytes += _amountRow(generator, label, -bill.discount);
    }
    if (bill.containerCharge > 0) {
      bytes += _amountRow(generator, 'Container Charge', bill.containerCharge);
    }
    if (bill.areaCharge > 0) {
      bytes += _amountRow(
        generator,
        bill.areaChargeLabel == null || bill.areaChargeLabel!.isEmpty
            ? 'AC / Area Charge'
            : 'AC / Area Charge (${bill.areaChargeLabel})',
        bill.areaCharge,
      );
    }
    if (bill.taxBreakdown.isNotEmpty) {
      for (final t in bill.taxBreakdown) {
        bytes += _amountRow(generator, t.key, t.value);
      }
    } else if (bill.taxTotal > 0) {
      bytes += _amountRow(generator, 'Tax', bill.taxTotal);
    }
    if (bill.roundOff != 0) {
      bytes += _amountRow(generator, 'Round Off', bill.roundOff);
    }
    bytes += generator.hr();

    bytes += generator.row([
      PosColumn(
        text: 'GRAND TOTAL',
        width: 7,
        styles: const PosStyles(bold: true, height: PosTextSize.size2),
      ),
      PosColumn(
        text: _currencyFormat.format(bill.grandTotal),
        width: 5,
        styles: const PosStyles(
          bold: true,
          align: PosAlign.right,
          height: PosTextSize.size2,
        ),
      ),
    ]);

    bytes += generator.hr();
    bytes += generator.text(
      _safe(bill.footer ?? 'THANKS FOR VISITING US'),
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }

  List<int> _amountRow(Generator g, String label, double amount, {bool bold = false}) {
    return g.row([
      PosColumn(text: _safe(label), width: 8, styles: PosStyles(bold: bold)),
      PosColumn(
        text: _currencyFormat.format(amount),
        width: 4,
        styles: PosStyles(align: PosAlign.right, bold: bold),
      ),
    ]);
  }
}
