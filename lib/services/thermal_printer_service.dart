import 'dart:io';

import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/table_model.dart';
import '../models/cart_model.dart';

/// Device-local receipt preferences (admin keeps receipt customization in
/// localStorage per till too — it is not server data a waiter can read).
class ReceiptPrefs {
  final String header;
  final PaperSize paperSize;
  final String printerIp;
  final int printerPort;

  /// Admin POS rule: allow "Release" at KOT_PRINT/RUNNING without a printed bill.
  final bool kotEnableReleaseTable;

  const ReceiptPrefs({
    required this.header,
    required this.paperSize,
    required this.printerIp,
    required this.printerPort,
    required this.kotEnableReleaseTable,
  });

  bool get printerConfigured => printerIp.isNotEmpty;

  static Future<ReceiptPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    final paper = prefs.getString('printer_paper') ?? '80mm';
    return ReceiptPrefs(
      header: prefs.getString('printer_header') ?? 'THE FAT FOX',
      paperSize: paper.contains('58') ? PaperSize.mm58 : PaperSize.mm80,
      printerIp: prefs.getString('printer_ip') ?? '',
      printerPort: int.tryParse(prefs.getString('printer_port') ?? '9100') ?? 9100,
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
  final NumberFormat _currencyFormat = NumberFormat.currency(
    symbol: '₹',
    decimalDigits: 2,
  );
  final DateFormat _dateFormat = DateFormat('dd MMM yyyy • h:mm a');

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

  /// Direct LAN ESC/POS over TCP :9100 (silent — no system dialog).
  Future<void> printBytes(List<int> bytes) async {
    final prefs = await ReceiptPrefs.load();
    if (!prefs.printerConfigured) {
      throw Exception('Printer IP not configured. Open Printer Settings.');
    }
    await sendRaw(bytes, host: prefs.printerIp, port: prefs.printerPort);
  }

  Future<List<int>> generateTestBytes({
    String header = 'THE FAT FOX',
    PaperSize paperSize = PaperSize.mm80,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    List<int> bytes = [];

    bytes += generator.text(
      header,
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
      'LAN thermal printer ready',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.text(
      'Date: ${_dateFormat.format(DateTime.now())}',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.hr();
    bytes += generator.text(
      'Silent print via TCP port 9100',
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
      restaurantName,
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    if (department != null && department.isNotEmpty) {
      bytes += generator.text(
        'DEPARTMENT : $department',
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
    }

    bytes += generator.feed(1);
    bytes += generator.text(
      'Table #: ${table.tableNumber}',
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
        PosColumn(text: name, width: 9),
        PosColumn(
          text: 'x${line.quantity}',
          width: 3,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);
      for (final addon in line.selectedAddons) {
        bytes += generator.text('   + ${addon.valueName.isNotEmpty ? addon.valueName : addon.name}');
      }
      if (line.instruction != null && line.instruction!.isNotEmpty) {
        bytes += generator.text('   Note: ${line.instruction}');
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
      bill.restaurantName,
      styles: const PosStyles(
        align: PosAlign.center,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
        bold: true,
      ),
    );
    if (bill.address != null && bill.address!.isNotEmpty) {
      bytes += generator.text(bill.address!, styles: const PosStyles(align: PosAlign.center));
    }
    if (bill.phone != null && bill.phone!.isNotEmpty) {
      bytes += generator.text('Ph: ${bill.phone}', styles: const PosStyles(align: PosAlign.center));
    }
    if (bill.gstin != null && bill.gstin!.isNotEmpty) {
      bytes += generator.text('GSTIN: ${bill.gstin}', styles: const PosStyles(align: PosAlign.center));
    }
    bytes += generator.hr();
    bytes += generator.text('Date: ${_dateFormat.format(DateTime.now())}');
    bytes += generator.text(
      'Table No : ${bill.tableNumber}',
      styles: const PosStyles(bold: true),
    );
    if (bill.paymentMode != null && bill.paymentMode!.isNotEmpty) {
      bytes += generator.text('Payment : ${bill.paymentMode}');
    }
    if (bill.customerName != null && bill.customerName!.isNotEmpty) {
      bytes += generator.text('Name : ${bill.customerName}');
    }
    if (bill.customerMobile != null && bill.customerMobile!.isNotEmpty) {
      bytes += generator.text('Mobile : ${bill.customerMobile}');
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
        PosColumn(text: name, width: 6),
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
        bytes += generator.text('   + $a');
      }
      if (line.note != null && line.note!.isNotEmpty) {
        bytes += generator.text('   (${line.note})');
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
      bill.footer ?? 'THANKS FOR VISITING US',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }

  List<int> _amountRow(Generator g, String label, double amount, {bool bold = false}) {
    return g.row([
      PosColumn(text: label, width: 8, styles: PosStyles(bold: bold)),
      PosColumn(
        text: _currencyFormat.format(amount),
        width: 4,
        styles: PosStyles(align: PosAlign.right, bold: bold),
      ),
    ]);
  }
}
