import 'dart:io';

import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:intl/intl.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/table_model.dart';
import '../models/cart_model.dart';
import '../models/receipt_customization.dart';

/// Lowest/highest values `Socket.connect` accepts — anything outside this
/// throws `ArgumentError: Invalid argument(s): Invalid port <n>` instead of
/// a friendly message, so every reader/writer of a printer port must clamp
/// to this range first.
const int kMinTcpPort = 1;
const int kMaxTcpPort = 65535;

bool isValidTcpPort(int? port) =>
    port != null && port >= kMinTcpPort && port <= kMaxTcpPort;

enum _ColAlign { left, center, right }

/// One column of a `_tableRow` — [width] is in twelfths, matching
/// `PosColumn.width`, so existing column proportions carry over unchanged.
class _Col {
  final String text;
  final int width;
  final _ColAlign align;

  const _Col(this.text, this.width, {this.align = _ColAlign.left});
}

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

  /// Characters per printed line for the printer's default font — mirrors
  /// esc_pos_utils' own `_getMaxCharsPerLine` for `PosFontType.fontA` (the
  /// only font this app uses), since table rows must agree with it exactly.
  int _charsPerLine(PaperSize paperSize) =>
      paperSize == PaperSize.mm58 ? 32 : 48;

  /// Lays out [cols] as ONE line of plain space-padded text instead of using
  /// `Generator.row()`. `row()` positions each column with an ESC/POS
  /// "move to absolute dot position" command, which many generic/Bluetooth
  /// thermal printers don't honor — the cursor never actually moves, so
  /// every column prints back-to-back with no visible gap. Literal space
  /// bytes work on any ESC/POS printer. [widthMultiplier] halves (or more)
  /// the usable characters per line for double-width text (e.g. size2).
  String _tableRow(
    PaperSize paperSize,
    List<_Col> cols, {
    int widthMultiplier = 1,
  }) {
    assert(cols.fold<int>(0, (sum, c) => sum + c.width) == 12);
    final totalChars = _charsPerLine(paperSize) ~/ widthMultiplier;
    var allocated = 0;
    final parts = <String>[];
    for (var i = 0; i < cols.length; i++) {
      final isLast = i == cols.length - 1;
      final chars = isLast
          ? totalChars - allocated
          : (cols[i].width * totalChars / 12).round();
      allocated += chars;
      final text = _safe(cols[i].text);
      final clipped = text.length > chars ? text.substring(0, chars) : text;
      final gap = chars - clipped.length;
      switch (cols[i].align) {
        case _ColAlign.right:
          parts.add('${' ' * gap}$clipped');
        case _ColAlign.center:
          final left = gap ~/ 2;
          parts.add('${' ' * left}$clipped${' ' * (gap - left)}');
        case _ColAlign.left:
          parts.add('$clipped${' ' * gap}');
      }
    }
    return parts.join();
  }

  /// `restaurantNameAlignment`/`footerAlignment` from [ReceiptCustomization]
  /// are free-text strings synced from the admin exe/website — never trust
  /// them as an enum value straight off the wire.
  PosAlign _alignFrom(String value) {
    switch (value.toLowerCase()) {
      case 'left':
        return PosAlign.left;
      case 'right':
        return PosAlign.right;
      default:
        return PosAlign.center;
    }
  }

  bool _isBold(ReceiptCustomization c) => c.fontWeight.toLowerCase() == 'bold';

  /// Builds a currency formatter from [ReceiptCustomization.currencySymbol],
  /// routed through [_safe] — admin's default is '₹', which is outside
  /// Latin-1 and would otherwise crash every raw ESC/POS print (see [_safe]).
  NumberFormat _buildCurrencyFormat(ReceiptCustomization c) =>
      NumberFormat.currency(symbol: '${_safe(c.currencySymbol)} ', decimalDigits: 2);

  /// Combines [ReceiptCustomization.dateFormat] + `timeFormat` into one
  /// `intl` pattern. Falls back to the fixed default pattern if the synced
  /// value is malformed — a bad string from the server must never crash
  /// every print for a tenant.
  String _formatDateTime(DateTime dt, ReceiptCustomization c) {
    final timePattern = c.timeFormat == '24h' ? 'HH:mm' : 'hh:mm a';
    try {
      return DateFormat('${c.dateFormat} $timePattern').format(dt);
    } catch (_) {
      return _dateFormat.format(dt);
    }
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
    ReceiptCustomization customization = ReceiptCustomization.defaults,
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

    if (customization.showRestaurantName) {
      bytes += generator.text(
        _safe(restaurantName),
        styles: PosStyles(align: _alignFrom(customization.restaurantNameAlignment), bold: true),
      );
    }
    if (customization.customHeaderLine1.isNotEmpty) {
      bytes += generator.text(
        _safe(customization.customHeaderLine1),
        styles: const PosStyles(align: PosAlign.center),
      );
    }
    if (customization.customHeaderLine2.isNotEmpty) {
      bytes += generator.text(
        _safe(customization.customHeaderLine2),
        styles: const PosStyles(align: PosAlign.center),
      );
    }
    if (department != null &&
        department.isNotEmpty &&
        customization.kotShowDepartmentName) {
      bytes += generator.text(
        _safe('DEPARTMENT : $department'),
        styles: const PosStyles(align: PosAlign.center, bold: true),
      );
    }

    bytes += generator.feed(1);
    if (customization.kotShowTableNumber) {
      bytes += generator.text(
        _safe('Table #: ${table.tableNumber}'),
        styles: const PosStyles(bold: true, height: PosTextSize.size2),
      );
    }
    if (customization.kotShowDate) {
      bytes += generator.text(
        'Date: ${_formatDateTime(DateTime.now(), customization)}',
      );
    }
    bytes += generator.hr();

    bytes += generator.text(
      _tableRow(paperSize, const [
        _Col('Item Name', 8),
        _Col('Qty', 4, align: _ColAlign.right),
      ]),
      styles: const PosStyles(bold: true),
    );
    bytes += generator.hr();

    var serial = 0;
    for (var line in items) {
      serial++;
      String name = line.item.name;
      if (customization.kotShowVariant && line.selectedVariant != null) {
        name += ' (${line.selectedVariant!.name})';
      }
      if (line.cancelStatus == 1) name += ' (cancelled)';
      if (customization.kotShowSerialNumber) name = '$serial. $name';
      bytes += generator.text(
        _tableRow(paperSize, [
          _Col(name, 9),
          _Col('x${line.quantity}', 3, align: _ColAlign.right),
        ]),
        styles: PosStyles(bold: _isBold(customization)),
      );
      if (customization.kotShowAddons) {
        for (final addon in line.selectedAddons) {
          bytes += generator.text(_safe(
              '   + ${addon.valueName.isNotEmpty ? addon.valueName : addon.name}'));
        }
      }
      if (customization.kotShowItemDescription &&
          line.instruction != null &&
          line.instruction!.isNotEmpty) {
        bytes += generator.text(_safe('   Note: ${line.instruction}'));
      }
    }

    if (customization.kotCustomMessage.isNotEmpty) {
      bytes += generator.hr();
      bytes += generator.text(
        _safe(customization.kotCustomMessage),
        styles: const PosStyles(align: PosAlign.center),
      );
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
    ReceiptCustomization customization = ReceiptCustomization.defaults,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(paperSize, profile);
    final currencyFormat = _buildCurrencyFormat(customization);

    List<int> buildCopy() {
      List<int> bytes = [];

      if (customization.showRestaurantName) {
        bytes += generator.text(
          _safe(bill.restaurantName),
          styles: PosStyles(
            align: _alignFrom(customization.restaurantNameAlignment),
            height: PosTextSize.size2,
            width: PosTextSize.size2,
            bold: true,
          ),
        );
      }
      if (customization.customHeaderLine1.isNotEmpty) {
        bytes += generator.text(
          _safe(customization.customHeaderLine1),
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (customization.customHeaderLine2.isNotEmpty) {
        bytes += generator.text(
          _safe(customization.customHeaderLine2),
          styles: const PosStyles(align: PosAlign.center),
        );
      }
      if (customization.showRestaurantAddress &&
          bill.address != null &&
          bill.address!.isNotEmpty) {
        bytes += generator.text(_safe(bill.address!), styles: const PosStyles(align: PosAlign.center));
      }
      if (customization.showRestaurantPhone &&
          bill.phone != null &&
          bill.phone!.isNotEmpty) {
        bytes += generator.text(_safe('Ph: ${bill.phone}'), styles: const PosStyles(align: PosAlign.center));
      }
      if (customization.showRestaurantGstin &&
          bill.gstin != null &&
          bill.gstin!.isNotEmpty) {
        bytes += generator.text(_safe('GSTIN: ${bill.gstin}'), styles: const PosStyles(align: PosAlign.center));
      }
      bytes += generator.hr();
      if (customization.billShowDate) {
        bytes += generator.text('Date: ${_formatDateTime(DateTime.now(), customization)}');
      }
      if (customization.billShowTableOrOrderNo) {
        bytes += generator.text(
          _safe('Table No : ${bill.tableNumber}'),
          styles: const PosStyles(bold: true),
        );
      }
      if (customization.billShowPaymentMode &&
          bill.paymentMode != null &&
          bill.paymentMode!.isNotEmpty) {
        bytes += generator.text(_safe('Payment : ${bill.paymentMode}'));
      }
      if (customization.billShowCustomerName &&
          bill.customerName != null &&
          bill.customerName!.isNotEmpty) {
        bytes += generator.text(_safe('Name : ${bill.customerName}'));
      }
      if (customization.billShowCustomerPhone &&
          bill.customerMobile != null &&
          bill.customerMobile!.isNotEmpty) {
        bytes += generator.text(_safe('Mobile : ${bill.customerMobile}'));
      }
      bytes += generator.hr();

      bytes += generator.text(
        _tableRow(paperSize, const [
          _Col('Item', 6),
          _Col('Qty', 2, align: _ColAlign.center),
          _Col('Amount', 4, align: _ColAlign.right),
        ]),
        styles: const PosStyles(bold: true),
      );
      bytes += generator.hr();

      var serial = 0;
      for (final line in bill.lines) {
        serial++;
        var name = line.name;
        if (customization.billShowVariant &&
            line.variant != null &&
            line.variant!.isNotEmpty) {
          name += ' (${line.variant})';
        }
        if (line.cancelled) name += ' (cancelled)';
        if (customization.billShowSerialNumber) name = '$serial. $name';
        bytes += generator.text(
          _tableRow(paperSize, [
            _Col(name, 6),
            _Col('${line.quantity}', 2, align: _ColAlign.center),
            _Col(currencyFormat.format(line.lineTotal), 4, align: _ColAlign.right),
          ]),
          styles: PosStyles(bold: _isBold(customization)),
        );
        if (customization.billShowAddons) {
          for (final a in line.addons) {
            bytes += generator.text(_safe('   + $a'));
          }
        }
        if (customization.billShowItemDescription &&
            line.note != null &&
            line.note!.isNotEmpty) {
          bytes += generator.text(_safe('   (${line.note})'));
        }
      }

      bytes += generator.hr();
      if (customization.billShowSubtotal) {
        bytes += _amountRow(generator, paperSize, currencyFormat, 'Subtotal', bill.subTotal, bold: true);
      }
      if (customization.billShowDiscount && bill.discount > 0) {
        final label = bill.discountName == null || bill.discountName!.isEmpty
            ? 'Discount'
            : 'Discount (${bill.discountName})';
        bytes += _amountRow(generator, paperSize, currencyFormat, label, -bill.discount);
      }
      if (customization.billShowContainerCharge && bill.containerCharge > 0) {
        bytes += _amountRow(generator, paperSize, currencyFormat, 'Container Charge', bill.containerCharge);
      }
      if (customization.billShowAreaCharge && bill.areaCharge > 0) {
        bytes += _amountRow(
          generator,
          paperSize,
          currencyFormat,
          bill.areaChargeLabel == null || bill.areaChargeLabel!.isEmpty
              ? 'AC / Area Charge'
              : 'AC / Area Charge (${bill.areaChargeLabel})',
          bill.areaCharge,
        );
      }
      if (customization.billShowTaxBreakdown) {
        if (bill.taxBreakdown.isNotEmpty) {
          for (final t in bill.taxBreakdown) {
            bytes += _amountRow(generator, paperSize, currencyFormat, t.key, t.value);
          }
        } else if (bill.taxTotal > 0) {
          bytes += _amountRow(generator, paperSize, currencyFormat, 'Tax', bill.taxTotal);
        }
      }
      if (customization.billShowRoundOff && bill.roundOff != 0) {
        bytes += _amountRow(generator, paperSize, currencyFormat, 'Round Off', bill.roundOff);
      }
      bytes += generator.hr();

      if (customization.billShowGrandTotal) {
        bytes += generator.text(
          // Only height is doubled here (as before) — PosTextSize.height alone
          // doesn't change how many characters fit per line, only .width does,
          // so the normal (undivided) character budget still applies.
          _tableRow(paperSize, [
            const _Col('GRAND TOTAL', 7),
            _Col(currencyFormat.format(bill.grandTotal), 5, align: _ColAlign.right),
          ]),
          styles: const PosStyles(bold: true, height: PosTextSize.size2),
        );
        bytes += generator.hr();
      }

      final footerAlign = _alignFrom(customization.footerAlignment);
      bytes += generator.text(
        _safe(bill.footer ?? customization.footerThankYouMessage),
        styles: PosStyles(align: footerAlign, bold: true),
      );
      if (customization.footerSubMessage.isNotEmpty) {
        bytes += generator.text(
          _safe(customization.footerSubMessage),
          styles: PosStyles(align: footerAlign),
        );
      }
      if (customization.customFooterLine1.isNotEmpty) {
        bytes += generator.text(
          _safe(customization.customFooterLine1),
          styles: PosStyles(align: footerAlign),
        );
      }
      if (customization.customFooterLine2.isNotEmpty) {
        bytes += generator.text(
          _safe(customization.customFooterLine2),
          styles: PosStyles(align: footerAlign),
        );
      }
      return bytes;
    }

    List<int> bytes = [];
    bytes += buildCopy();
    bytes += generator.feed(2);
    bytes += generator.cut();
    if (customization.billShowCustomerCopy) {
      bytes += buildCopy();
      bytes += generator.feed(2);
      bytes += generator.cut();
    }

    return bytes;
  }

  List<int> _amountRow(
    Generator g,
    PaperSize paperSize,
    NumberFormat currencyFormat,
    String label,
    double amount, {
    bool bold = false,
  }) {
    return g.text(
      _tableRow(paperSize, [
        _Col(label, 8),
        _Col(currencyFormat.format(amount), 4, align: _ColAlign.right),
      ]),
      styles: PosStyles(bold: bold),
    );
  }
}
