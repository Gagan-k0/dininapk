import 'dart:io';

import 'package:flutter/material.dart' show DateUtils, debugPrint, visibleForTesting;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Generates a CSV file from settled order data and saves it to the device.
///
/// No external dependencies — uses [dart:io] for file writes and [intl] for
/// date formatting (already a project dependency).
class CsvExportService {
  CsvExportService._();

  // ── public API ──────────────────────────────────────────────

  /// Build a CSV string from [orders] (the raw JSON maps returned by
  /// `GET /restaurant/order`).  Each **line item** inside an order becomes
  /// its own row so the user can sort/filter in a spreadsheet.
  static String buildCsv(List<Map<String, dynamic>> orders) =>
      encode(buildRows(orders));

  /// [rows] as RFC 4180 CSV text.
  static String encode(List<List<String>> rows) =>
      '${rows.map(_row).join('\n')}\n';

  /// The same table as [buildCsv], unescaped — header first. The in-app
  /// viewer shows exactly what the file holds without re-parsing it.
  static List<List<String>> buildRows(List<Map<String, dynamic>> orders) {
    final rows = <List<String>>[];
    // Header
    rows.add([
      'Order Date',
      'Order Time',
      'Bill No.',
      'Table No.',
      'Item Name',
      'Variant',
      'Add-ons',
      'Qty',
      'Unit Price',
      'Line Total',
      'Subtotal',
      'Tax',
      'Discount',
      'Grand Total',
      'Payment',
      'Sync Status',
    ]);

    for (final o in orders) {
      final dt = _parseDate(o['createdAt'] ?? o['created_at']);
      final date = dt != null ? DateFormat('yyyy-MM-dd').format(dt) : '';
      final time = dt != null ? DateFormat('HH:mm').format(dt) : '';
      final billNo =
          (o['order_no'] ?? o['orderNo'] ?? o['_id'] ?? '').toString();
      final table = (o['table_number'] ??
              o['table_no'] ??
              o['table_name'] ??
              '')
          .toString();
      // The order list projects `menu_total`, not `food_subtotal`. An amount
      // the row does not carry stays blank rather than reading as 0.00.
      final subtotal = _cell(o['food_subtotal'] ?? o['menu_total']);
      final tax = _cell(o['tax_price']);
      final discount = _cell(o['discount_price']);
      final grand = _money(_num(o['total_price']));
      final sync = (o['_syncStatus'] ?? 'Online').toString();
      final payment =
          (o['payment_type'] ?? o['paymentType'] ?? '').toString();

      final lines = _extractLines(o);
      if (lines.isEmpty) {
        // Order with no line-item detail — still emit a summary row.
        rows.add([
          date,
          time,
          billNo,
          table,
          '',
          '',
          '',
          '',
          '',
          '',
          subtotal,
          tax,
          discount,
          grand,
          payment,
          sync,
        ]);
      } else {
        for (final l in lines) {
          rows.add([
            date,
            time,
            billNo,
            table,
            l.name,
            l.variant,
            l.addons,
            l.qty.toString(),
            _money(l.unitPrice),
            _money(l.lineTotal),
            subtotal,
            tax,
            discount,
            grand,
            payment,
            sync,
          ]);
        }
      }
    }
    return rows;
  }

  /// Where reports are saved, relative to shared storage — also what the
  /// waiter is told to look for in the Files app.
  static const String folder = 'Download/FatFox/Transactions';

  /// Writes [csv] to [folder] and returns the file. The name carries the
  /// report's date range and the save time, e.g.
  /// `FatFox_Transactions_21-Sep-2026_to_22-Sep-2026_saved_17-43-05.csv`
  /// (one date when the range is a single day), so reports sort and are
  /// found by the day they cover, and a second save never overwrites one.
  ///
  /// Android 10 and older refuse that write without the storage permission
  /// (asked only then — newer Android never needs it). If it is still
  /// refused, the file goes to this app's own folder on shared storage
  /// (Android/data/…/files/FatFox/Transactions), which needs no permission.
  /// [displayFolder] names wherever it actually landed.
  static Future<File> saveCsv(
    String csv, {
    required DateTime from,
    required DateTime to,
  }) async {
    final name = fileName(from, to, DateTime.now());
    final shared = Directory('$_sharedRoot/$folder');
    var file = await tryWrite(shared, name, csv);
    if (file == null && await Permission.storage.request().isGranted) {
      file = await tryWrite(shared, name, csv);
    }
    if (file == null) {
      final own = await getExternalStorageDirectory();
      if (own != null) {
        file = await tryWrite(Directory('${own.path}/FatFox/Transactions'), name, csv);
      }
    }
    if (file == null) {
      throw FileSystemException('Could not save the CSV', shared.path);
    }
    debugPrint('[Fatfox CSV] Saved ${file.path} (${csv.length} bytes)');
    return file;
  }

  static const String _sharedRoot = '/storage/emulated/0';

  /// Writes [csv] as [name] in [dir]; null when the folder refuses it.
  @visibleForTesting
  static Future<File?> tryWrite(Directory dir, String name, String csv) async {
    try {
      await dir.create(recursive: true);
      final file = File('${dir.path}/$name');
      await file.writeAsString(csv, flush: true);
      return file;
    } on FileSystemException {
      return null;
    }
  }

  /// [file]'s folder as the Files app shows it (relative to shared storage).
  static String displayFolder(File file) {
    final dir = file.parent.path;
    return dir.startsWith('$_sharedRoot/')
        ? dir.substring(_sharedRoot.length + 1)
        : dir;
  }

  static String fileName(DateTime from, DateTime to, DateTime savedAt) {
    final day = DateFormat('dd-MMM-yyyy');
    final range = DateUtils.isSameDay(from, to)
        ? day.format(from)
        : '${day.format(from)}_to_${day.format(to)}';
    return 'FatFox_Transactions_${range}_saved_'
        '${DateFormat('HH-mm-ss').format(savedAt)}.csv';
  }

  // ── CSV escaping ────────────────────────────────────────────

  /// RFC 4180: fields with commas, quotes, or newlines are quoted;
  /// internal quotes are doubled.
  static String _esc(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  static String _row(List<String> cells) => cells.map(_esc).join(',');

  // ── line-item extraction (mirrors BillBuilder.cartLinesToBillLines) ──

  static List<_CsvLine> _extractLines(Map<String, dynamic> order) {
    final raw = order['cartMenuData'] ?? order['orderMenuData'];
    if (raw is! List) return const [];
    final out = <_CsvLine>[];
    for (final m in raw) {
      if (m is! Map) continue;
      if (m['cancel_status'] == 1 || m['cancel_status'] == '1') continue;

      // Item name
      final menuData = m['menuData'];
      final menu =
          (menuData is List && menuData.isNotEmpty && menuData.first is Map)
              ? Map<String, dynamic>.from(menuData.first as Map)
              : (menuData is Map
                  ? Map<String, dynamic>.from(menuData)
                  : null);
      final name = (menu?['displayname'] ??
              menu?['name'] ??
              m['menu_name'] ??
              'Item')
          .toString();

      // Variant
      final variantRaw = m['variant'];
      String variant = '';
      if (variantRaw is List &&
          variantRaw.isNotEmpty &&
          variantRaw.first is Map) {
        variant = (variantRaw.first['valuename'] ??
                variantRaw.first['name'] ??
                '')
            .toString();
      } else if (variantRaw is Map) {
        variant =
            (variantRaw['valuename'] ?? variantRaw['name'] ?? '').toString();
      }
      if (variant.isEmpty && m['variant_name'] != null) {
        variant = m['variant_name'].toString();
      }

      // Add-ons
      final addonBuf = <String>[];
      final addonData = m['addonData'] ?? m['addons'];
      if (addonData is List) {
        for (final a in addonData) {
          if (a is Map) {
            final v = a['value'];
            final label = v is Map
                ? (v['valuename'] ?? v['name'] ?? v['displayname'])
                : (a['valuename'] ??
                    a['name'] ??
                    a['displayname'] ??
                    a['addon_name']);
            if (label != null && label.toString().trim().isNotEmpty) {
              addonBuf.add(label.toString().trim());
            }
          }
        }
      }

      out.add(_CsvLine(
        name: name,
        variant: variant,
        addons: addonBuf.join('; '),
        qty: int.tryParse(m['quantity']?.toString() ?? '1') ?? 1,
        unitPrice: _num(m['menu_price'] ?? m['individual_price']),
        lineTotal: _num(m['price']),
      ));
    }
    return out;
  }

  // ── helpers ─────────────────────────────────────────────────

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }

  static String _money(double v) => v.toStringAsFixed(2);

  static String _cell(dynamic v) => v == null ? '' : _money(_num(v));

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    // Server timestamps are UTC; the sheet shows the restaurant's local day.
    if (v is DateTime) return v.toLocal();
    return DateTime.tryParse(v.toString())?.toLocal();
  }
}

class _CsvLine {
  final String name;
  final String variant;
  final String addons;
  final int qty;
  final double unitPrice;
  final double lineTotal;

  const _CsvLine({
    required this.name,
    required this.variant,
    required this.addons,
    required this.qty,
    required this.unitPrice,
    required this.lineTotal,
  });
}
