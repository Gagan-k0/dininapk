import 'dart:io';

import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/table_model.dart';
import '../models/cart_model.dart';

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

  Future<void> printBytes(List<int> bytes) async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('printer_ip') ?? '';
    final port =
        int.tryParse(prefs.getString('printer_port') ?? '9100') ?? 9100;
    if (host.isEmpty) {
      throw Exception('Printer IP not configured. Open Printer Settings.');
    }
    await sendRaw(bytes, host: host, port: port);
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
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    List<int> bytes = [];

    // Header
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

    bytes += generator.feed(1);
    bytes += generator.text(
      'Table #: ${table.tableNumber}',
      styles: const PosStyles(bold: true, height: PosTextSize.size2),
    );
    bytes += generator.text('Date: ${_dateFormat.format(DateTime.now())}');
    bytes += generator.hr();

    // Column Headers
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

    // Line items
    for (var line in items) {
      String name = line.item.name;
      if (line.selectedVariant != null) {
        name += ' (${line.selectedVariant!.name})';
      }
      bytes += generator.row([
        PosColumn(text: name, width: 9),
        PosColumn(
          text: 'x${line.quantity}',
          width: 3,
          styles: const PosStyles(align: PosAlign.right, bold: true),
        ),
      ]);

      if (line.instruction != null && line.instruction!.isNotEmpty) {
        bytes += generator.text('   Note: ${line.instruction}');
      }
    }

    bytes += generator.hr();
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }

  // Generate Customer Bill Byte Stream
  Future<List<int>> generateBillBytes({
    required DineInTable table,
    required List<CartLineItem> items,
    required double subTotal,
    required double taxAmount,
    required double grandTotal,
    required String restaurantName,
    dynamic paperSize = PaperSize.mm80,
  }) async {
    final size = (paperSize is String && paperSize.contains('58'))
        ? PaperSize.mm58
        : (paperSize is PaperSize ? paperSize : PaperSize.mm80);
    final profile = await CapabilityProfile.load();
    final generator = Generator(size, profile);
    List<int> bytes = [];

    bytes += generator.text(
      restaurantName,
      styles: const PosStyles(
        align: PosAlign.center,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
        bold: true,
      ),
    );
    bytes += generator.text(
      'DINE-IN CUSTOMER RECEIPT',
      styles: const PosStyles(align: PosAlign.center),
    );
    bytes += generator.text(
      'Table #: ${table.tableNumber}',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.text(
      'Date: ${_dateFormat.format(DateTime.now())}',
      styles: const PosStyles(align: PosAlign.center),
    );
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

    for (var line in items) {
      bytes += generator.row([
        PosColumn(text: line.item.name, width: 6),
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
    }

    bytes += generator.hr();
    bytes += generator.row([
      PosColumn(
        text: 'Subtotal',
        width: 8,
        styles: const PosStyles(bold: true),
      ),
      PosColumn(
        text: _currencyFormat.format(subTotal),
        width: 4,
        styles: const PosStyles(align: PosAlign.right, bold: true),
      ),
    ]);
    bytes += generator.row([
      PosColumn(text: 'Taxes (GST)', width: 8),
      PosColumn(
        text: _currencyFormat.format(taxAmount),
        width: 4,
        styles: const PosStyles(align: PosAlign.right),
      ),
    ]);
    bytes += generator.hr();

    bytes += generator.row([
      PosColumn(
        text: 'GRAND TOTAL',
        width: 7,
        styles: const PosStyles(bold: true, height: PosTextSize.size2),
      ),
      PosColumn(
        text: _currencyFormat.format(grandTotal),
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
      'Thank You! Please Visit Again',
      styles: const PosStyles(align: PosAlign.center, bold: true),
    );
    bytes += generator.feed(2);
    bytes += generator.cut();

    return bytes;
  }
}
