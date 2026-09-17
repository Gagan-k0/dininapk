import '../models/table_model.dart';
import 'api_service.dart';
import 'thermal_printer_service.dart';

/// Turns the live cart into [BillPrintData], the way the admin
/// `print-dinein-save` page does:
/// * header from `vieworder-save` (restaurant name/address/gstin, customer, totals);
/// * lines from the cart snapshot (`listallcartmenus`) — complete, cancel-filtered,
///   at BASE unit price (the area surge is its own row);
/// * tax breakdown from `settax` rows split proportionally over `tax_price`
///   (the API returns only the lumped `tax_price`).
class BillBuilder {
  final ApiService _api;
  BillBuilder(this._api);

  Future<BillPrintData?> build({
    required String tableId,
    required String tableNumber,
    List<TableArea> areas = const [],
    String? paymentMode,
    Map<String, dynamic>? cartSnapshot,
    List<Map<String, dynamic>>? taxRows,
  }) async {
    final cart = cartSnapshot ?? await _firstCart(tableId);
    if (cart == null) return null;

    Map<String, dynamic>? header;
    try {
      header = await _api.getBillView(tableId, fresh: true);
    } on ApiException catch (e) {
      if (e.isAuth) rethrow;
      header = null; // bill still prints from the snapshot
    }
    final rest = _restaurantDoc(header);

    final rows = taxRows ?? await _safeTaxRows();
    final merged = {...cart, ...?header};

    final lines = cartLinesToBillLines(cart);
    final foodSubtotal = _num(merged['food_subtotal']) > 0
        ? _num(merged['food_subtotal'])
        : lines.where((l) => !l.cancelled).fold(0.0, (s, l) => s + l.lineTotal);
    final taxTotal = _num(merged['tax_price']);
    final total = _num(merged['total_price']);
    final unrounded = _num(merged['unrounded_total']);
    final roundOff = merged['round_off'] != null
        ? _num(merged['round_off'])
        : (unrounded > 0 ? total - unrounded : 0.0);

    return BillPrintData(
      restaurantName: (rest?['name'] ?? merged['restaurant_name'] ?? 'THE FAT FOX').toString(),
      address: (rest?['address'] ?? merged['restaurant_address'])?.toString(),
      phone: (rest?['mobile'] ?? merged['restaurant_mobile'])?.toString(),
      gstin: rest?['gstin']?.toString(),
      tableNumber: tableNumber,
      paymentMode: paymentMode,
      customerName: merged['customer_name']?.toString(),
      customerMobile: merged['customer_mobileno']?.toString(),
      lines: lines,
      subTotal: foodSubtotal,
      discount: _num(merged['discount_price']),
      discountName: merged['discount_name']?.toString(),
      containerCharge: _num(merged['container_price']),
      areaCharge: _num(merged['area_charge']),
      areaChargeLabel: _surgeLabel(cart, areas),
      taxBreakdown: splitTax(taxTotal, rows),
      taxTotal: taxTotal,
      roundOff: double.parse(roundOff.toStringAsFixed(2)),
      grandTotal: total,
    );
  }

  Future<Map<String, dynamic>?> _firstCart(String tableId) async {
    final carts = await _api.getCartItemsByTableId(tableId, fresh: true);
    return carts.isEmpty ? null : carts.first;
  }

  Future<List<Map<String, dynamic>>> _safeTaxRows() async {
    try {
      return await _api.getTaxConfig();
    } on ApiException catch (e) {
      if (e.isAuth) rethrow;
      return const [];
    }
  }

  static Map<String, dynamic>? _restaurantDoc(Map<String, dynamic>? header) {
    final r = header?['restaurant'];
    if (r is List && r.isNotEmpty && r.first is Map) {
      return Map<String, dynamic>.from(r.first as Map);
    }
    if (r is Map) return Map<String, dynamic>.from(r);
    return null;
  }

  static String? _surgeLabel(Map<String, dynamic> cart, List<TableArea> areas) {
    final areaId = cart['area_id']?.toString();
    for (final a in areas) {
      if (a.id == areaId && a.surgeValue > 0) {
        return a.surgeType == 'flat'
            ? '₹${a.surgeValue.toStringAsFixed(0)}/item'
            : '${a.surgeValue.toStringAsFixed(a.surgeValue % 1 == 0 ? 0 : 2)}%';
      }
    }
    return null;
  }

  /// Cart snapshot lines → bill lines (cancelled rows dropped, extra add-ons
  /// rendered from `menu_name` because they have no `menuData`).
  static List<BillLine> cartLinesToBillLines(Map<String, dynamic> cart) {
    final raw = cart['cartMenuData'];
    if (raw is! List) return const [];
    final out = <BillLine>[];
    for (final m in raw) {
      if (m is! Map) continue;
      if (m['cancel_status'] == 1 || m['cancel_status'] == '1') continue;
      final menuData = m['menuData'];
      final menu = (menuData is List && menuData.isNotEmpty && menuData.first is Map)
          ? Map<String, dynamic>.from(menuData.first as Map)
          : (menuData is Map ? Map<String, dynamic>.from(menuData) : null);
      final name = (menu?['displayname'] ?? menu?['name'] ?? m['menu_name'] ?? 'Item').toString();
      final variantRaw = m['variant'];
      String? variant;
      if (variantRaw is List && variantRaw.isNotEmpty && variantRaw.first is Map) {
        variant = (variantRaw.first['valuename'] ?? variantRaw.first['name'])?.toString();
      } else if (variantRaw is Map) {
        variant = (variantRaw['valuename'] ?? variantRaw['name'])?.toString();
      }
      final addons = <String>[];
      final addonData = m['addonData'];
      if (addonData is List) {
        for (final a in addonData) {
          if (a is Map) {
            final v = a['value'];
            final label = v is Map ? (v['valuename'] ?? v['name']) : (a['valuename'] ?? a['name']);
            if (label != null) addons.add(label.toString());
          }
        }
      }
      out.add(BillLine(
        name: name,
        variant: variant,
        addons: addons,
        note: m['description']?.toString(),
        quantity: int.tryParse(m['quantity']?.toString() ?? '1') ?? 1,
        lineTotal: _num(m['price']),
      ));
    }
    return out;
  }

  /// Splits the lumped `tax_price` across the configured tax rows by their
  /// `value_amount` weight — CGST 2.5 + SGST 2.5 over ₹21.90 → 10.95 each.
  static List<MapEntry<String, double>> splitTax(
    double taxTotal,
    List<Map<String, dynamic>> rows,
  ) {
    if (taxTotal <= 0 || rows.isEmpty) return const [];
    final weights = rows
        .map((r) => MapEntry(
              (r['name'] ?? r['tax_name'] ?? 'Tax').toString(),
              _num(r['value_amount']),
            ))
        .where((e) => e.value > 0)
        .toList();
    final sum = weights.fold(0.0, (s, e) => s + e.value);
    if (sum <= 0) return const [];
    var allocated = 0.0;
    final out = <MapEntry<String, double>>[];
    for (var i = 0; i < weights.length; i++) {
      final w = weights[i];
      final isLast = i == weights.length - 1;
      final share = isLast
          ? double.parse((taxTotal - allocated).toStringAsFixed(2))
          : double.parse((taxTotal * w.value / sum).toStringAsFixed(2));
      allocated += share;
      final pct = w.value % 1 == 0 ? w.value.toStringAsFixed(0) : w.value.toString();
      out.add(MapEntry('${w.key} ($pct%)', share));
    }
    return out;
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }
}
