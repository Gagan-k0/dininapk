import 'dart:io';

import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:intl/intl.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/table_model.dart';
import '../models/cart_model.dart';
import '../models/receipt_customization.dart';
import 'usb_printer.dart';

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

/// Which job a print is for — admin assigns a KOT printer and a Bill printer
/// separately, so a kitchen ticket never comes out at the billing counter.
enum PrinterRole { bill, kot }

/// One physical printer: a LAN host:port or a paired Bluetooth MAC.
///
/// Stored per device only, never in the server's `printer_config`: the admin
/// exe keeps Windows print-queue names there, which a raw IP/MAC would clobber.
class PrinterTarget {
  /// `LAN`, `Bluetooth` or `USB`.
  final String type;
  final String ip;
  final int port;
  final String btMac;
  final String btName;

  /// `vendorId:productId` of a USB printer (see [UsbPrinter.id]).
  final String usbId;
  final String usbName;

  const PrinterTarget({
    required this.type,
    required this.ip,
    required this.port,
    required this.btMac,
    required this.btName,
    this.usbId = '',
    this.usbName = '',
  });

  /// The Bill printer keeps the original single-printer keys so existing
  /// installs carry on printing without re-setup.
  static String prefixFor(PrinterRole role) => role == PrinterRole.kot ? 'kot_' : '';

  bool get isBluetooth => type.toLowerCase() == 'bluetooth';

  bool get isUsb => type.toLowerCase() == 'usb';

  bool get configured => isUsb
      ? usbId.isNotEmpty
      : isBluetooth
          ? btMac.isNotEmpty
          : ip.isNotEmpty;

  static PrinterTarget read(SharedPreferences prefs, PrinterRole role) {
    final p = prefixFor(role);
    final savedPort = int.tryParse(prefs.getString('${p}printer_port') ?? '9100');
    return PrinterTarget(
      type: prefs.getString('${p}printer_type') ?? 'LAN',
      ip: prefs.getString('${p}printer_ip') ?? '',
      // A bad value already saved (pre-dating validation, or hand-edited)
      // must not throw ArgumentError on every future print — fall back.
      port: isValidTcpPort(savedPort) ? savedPort! : 9100,
      btMac: prefs.getString('${p}printer_bt_mac') ?? '',
      btName: prefs.getString('${p}printer_bt_name') ?? '',
      usbId: prefs.getString('${p}printer_usb_id') ?? '',
      usbName: prefs.getString('${p}printer_usb_name') ?? '',
    );
  }
}

/// Device-local receipt preferences (admin keeps receipt customization in
/// localStorage per till too — it is not server data a waiter can read).
class ReceiptPrefs {
  static const String kotSameAsBillKey = 'kot_printer_same_as_bill';

  final String header;
  final PaperSize paperSize;
  final PrinterTarget bill;
  final PrinterTarget kot;

  /// True until a separate KOT printer is assigned — KOTs print on [bill].
  final bool kotSameAsBill;

  /// Admin POS rule: allow "Release" at KOT_PRINT/RUNNING without a printed bill.
  final bool kotEnableReleaseTable;

  const ReceiptPrefs({
    required this.header,
    required this.paperSize,
    required this.bill,
    required this.kot,
    required this.kotSameAsBill,
    required this.kotEnableReleaseTable,
  });

  PrinterTarget targetFor(PrinterRole role) =>
      role == PrinterRole.kot && !kotSameAsBill ? kot : bill;

  static ReceiptPrefs? _cachedPrefs;

  static Future<ReceiptPrefs> load({bool forceRefresh = false}) async {
    if (_cachedPrefs != null && !forceRefresh) return _cachedPrefs!;
    final prefs = await SharedPreferences.getInstance();
    final paper = prefs.getString('printer_paper') ?? '80mm';
    _cachedPrefs = ReceiptPrefs(
      header: prefs.getString('printer_header') ?? 'THE FAT FOX',
      paperSize: paper.contains('58') ? PaperSize.mm58 : PaperSize.mm80,
      bill: PrinterTarget.read(prefs, PrinterRole.bill),
      kot: PrinterTarget.read(prefs, PrinterRole.kot),
      kotSameAsBill: prefs.getBool(kotSameAsBillKey) ?? true,
      kotEnableReleaseTable: prefs.getBool('kot_enable_release_table') ?? false,
    );
    return _cachedPrefs!;
  }

  static void invalidateCache() {
    _cachedPrefs = null;
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
  int _charsPerLine(PaperSize paperSize) => paperSize == PaperSize.mm58
      ? (_font == PosFontType.fontB ? 42 : 32)
      : (_font == PosFontType.fontB ? 64 : 48);

  /// Font of the ticket being generated — set at the start of each KOT/bill
  /// so [_tableRow] pads to the same width the printer wraps at.
  PosFontType _font = PosFontType.fontA;

  /// Admin small/medium/large: small = the printer's narrow Font B (more
  /// characters per line), large = double-height item rows.
  PosFontType _fontFor(String size) => size == 'small' ? PosFontType.fontB : PosFontType.fontA;

  PosTextSize _itemHeight(String size) => size == 'large' ? PosTextSize.size2 : PosTextSize.size1;

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

  static CapabilityProfile? _cachedProfile;

  static Future<CapabilityProfile> get _capabilityProfile async {
    _cachedProfile ??= await CapabilityProfile.load();
    return _cachedProfile!;
  }

  /// Pre-warms capability profile, receipt preferences, and Bluetooth link
  /// in the background so the very first print action (e.g. KOT) doesn't lag.
  static Future<void> warmup() async {
    try {
      await _capabilityProfile;
      final prefs = await ReceiptPrefs.load();
      final kotTarget = prefs.targetFor(PrinterRole.kot);
      final billTarget = prefs.targetFor(PrinterRole.bill);

      if (kotTarget.isBluetooth && kotTarget.btMac.isNotEmpty) {
        _connectBluetoothInBackground(kotTarget.btMac);
      } else if (billTarget.isBluetooth && billTarget.btMac.isNotEmpty) {
        _connectBluetoothInBackground(billTarget.btMac);
      }
    } catch (_) {}
  }

  static void _connectBluetoothInBackground(String mac) async {
    try {
      if (_connectedMac != mac) {
        final connected = await PrintBluetoothThermal.connectionStatus;
        if (!connected) {
          final ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
          if (ok) _connectedMac = mac;
        } else {
          _connectedMac = mac;
        }
      }
    } catch (_) {}
  }

  Future<void> sendRaw(
    List<int> bytes, {
    required String host,
    required int port,
  }) async {
    final address = InternetAddress.tryParse(host) ?? host;
    final socket = await Socket.connect(
      address,
      port,
      timeout: const Duration(seconds: 3),
    );
    try {
      socket.add(bytes);
      await socket.flush();
      await Future.delayed(const Duration(milliseconds: 50));
    } finally {
      socket.destroy();
    }
  }

  /// Silent ESC/POS — LAN TCP :9100 or Bluetooth SPP. Never uses PrintManager.
  /// [role] picks the assigned KOT or Bill printer.
  Future<void> printBytes(List<int> bytes, {PrinterRole role = PrinterRole.bill}) async {
    final prefs = await ReceiptPrefs.load();
    final target = prefs.targetFor(role);
    final label = role == PrinterRole.kot && !prefs.kotSameAsBill ? 'KOT' : 'Bill';
    if (!target.configured) {
      throw Exception(
        target.isUsb
            ? '$label USB printer not selected. Open Printer Settings → $label printer → Scan.'
            : target.isBluetooth
                ? '$label Bluetooth printer not selected. Open Printer Settings → $label printer → Scan.'
                : '$label printer IP not configured. Open Printer Settings → $label printer.',
      );
    }
    if (target.isUsb) {
      await UsbPrinter.write(target.usbId, bytes);
      return;
    }
    if (target.isBluetooth) {
      await _sendBluetooth(bytes, mac: target.btMac);
      return;
    }
    await sendRaw(bytes, host: target.ip, port: target.port);
  }

  /// MAC of the link the Bluetooth plugin currently holds. Static because
  /// the plugin keeps ONE socket for the whole app, shared by every service
  /// instance (POS screen and Printer Settings each create their own).
  static String? _connectedMac;

  Future<void> _sendBluetooth(List<int> bytes, {required String mac}) async {
    bool isConnected = _connectedMac == mac;
    if (isConnected) {
      try {
        final status = await PrintBluetoothThermal.connectionStatus;
        if (!status) {
          isConnected = false;
          _connectedMac = null;
        }
      } catch (_) {
        isConnected = false;
        _connectedMac = null;
      }
    } else {
      try {
        final status = await PrintBluetoothThermal.connectionStatus;
        if (status) {
          await PrintBluetoothThermal.disconnect;
        }
      } catch (_) {}
    }

    if (!isConnected) {
      _connectedMac = null;
      try {
        final ok = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
        if (!ok) {
          throw Exception(
            'Could not connect to Bluetooth printer $mac. Pair it in Android Settings first.',
          );
        }
        _connectedMac = mac;
      } catch (e) {
        _connectedMac = null;
        if (e is Exception) rethrow;
        throw Exception('Could not connect to Bluetooth printer $mac: $e');
      }
    }

    bool written = false;
    try {
      written = await PrintBluetoothThermal.writeBytes(bytes);
    } catch (_) {
      written = false;
    }

    // If first attempt failed (e.g. stale socket), reconnect once & retry
    if (!written) {
      _connectedMac = null;
      try {
        await PrintBluetoothThermal.disconnect;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 200));
      try {
        final reconnected = await PrintBluetoothThermal.connect(macPrinterAddress: mac);
        if (reconnected) {
          _connectedMac = mac;
          written = await PrintBluetoothThermal.writeBytes(bytes);
        }
      } catch (_) {
        written = false;
      }
    }

    if (!written) {
      _connectedMac = null;
      throw Exception('Bluetooth printer failed to accept the print job. Make sure printer is turned ON and paired.');
    }
  }

  Future<List<int>> generateTestBytes({
    String header = 'THE FAT FOX',
    PaperSize paperSize = PaperSize.mm80,
    String title = 'TEST PRINT',
  }) async {
    final profile = await _capabilityProfile;
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
      _safe(title),
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
    final profile = await _capabilityProfile;
    final generator = Generator(paperSize, profile);
    _font = _fontFor(customization.kotFontSize);
    List<int> bytes = generator.setGlobalFont(_font);

    // Short on purpose: double-width halves the line (24 chars on 80mm, 16 on
    // 58mm), so a long title wrapped mid-word. Like admin's KOT, no restaurant
    // header — the kitchen only needs the table and items.
    bytes += generator.text(
      'KOT',
      styles: const PosStyles(
        align: PosAlign.center,
        height: PosTextSize.size2,
        width: PosTextSize.size2,
        bold: true,
      ),
    );

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
        styles: PosStyles(
          bold: _isBold(customization),
          height: _itemHeight(customization.kotFontSize),
        ),
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
    bytes += generator.feed(4);
    bytes += generator.cut();
    bytes += const [0x1d, 0x56, 0x00, 0x1d, 0x56, 0x01, 0x1b, 0x69];

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
    final profile = await _capabilityProfile;
    final generator = Generator(paperSize, profile);
    final currencyFormat = _buildCurrencyFormat(customization);
    _font = _fontFor(customization.billFontSize);
    final fontBytes = generator.setGlobalFont(_font);

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
        bytes += generator.text(
            _safe('Payment : ${bill.paymentMode!.toUpperCase().replaceAll('_', ' ')}'));
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
          styles: PosStyles(
            bold: _isBold(customization),
            height: _itemHeight(customization.billFontSize),
          ),
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

      // Admin prints this label on the single bill — not a second full bill.
      if (customization.billShowCustomerCopy) {
        bytes += generator.text(
          '--- CUSTOMER COPY ---',
          styles: const PosStyles(align: PosAlign.center, bold: true),
        );
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

    return [
      ...fontBytes,
      ...buildCopy(),
      ...generator.feed(4),
      ...generator.cut(),
      0x1d, 0x56, 0x00,
      0x1d, 0x56, 0x01,
      0x1b, 0x69,
    ];
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
