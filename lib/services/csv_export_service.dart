import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

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
  static String buildCsv(List<Map<String, dynamic>> orders) {
    final buf = StringBuffer();
    // Header
    buf.writeln(_row([
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
    ]));

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
        buf.writeln(_row([
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
        ]));
      } else {
        for (final l in lines) {
          buf.writeln(_row([
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
          ]));
        }
      }
    }
    return buf.toString();
  }

  /// Write [csv] to the device's Downloads folder and return the [File].
  ///
  /// On Android 10+ (API 29+) the app-specific external directory is
  /// world-readable so a file manager can find it.  For older devices the
  /// same path works without needing WRITE_EXTERNAL_STORAGE because
  /// `getExternalStorageDirectory()` is scoped.
  static Future<File> saveCsv(String csv, {String? fileName}) async {
    final name = fileName ??
        'fatfox_transactions_${DateFormat('yyyy-MM-dd_HHmm').format(DateTime.now())}.csv';

    // Try the shared Downloads folder first (visible in file managers).
    final downloadsDir = Directory('/storage/emulated/0/Download');
    final dir = await downloadsDir.exists()
        ? downloadsDir
        : Directory('/storage/emulated/0/Documents');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final file = File('${dir.path}/$name');
    await file.writeAsString(csv, flush: true);
    debugPrint('[Fatfox CSV] Saved ${file.path} (${csv.length} bytes)');
    return file;
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
