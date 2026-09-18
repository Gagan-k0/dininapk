/// Offline dine-in bill pricing — a line-for-line mirror of the api-server.
///
/// The tablet must be able to price a bill with no network and have the paper
/// match, to the paisa, what the server will record when the sale syncs. That
/// makes this file a MIRROR, not an implementation: every branch below exists
/// because a branch exists in one of these four server helpers, and the server
/// wins every disagreement.
///
///   fatfox-api-server (origin/main)
///     helpers/dineinBillTotal.js   resolveDineinCartPricing — the composition
///     helpers/taxCalculator.js     round2 / computePickupTax — the tax engine
///     helpers/areaSurge.js         normalizeAreaSurge / areaChargeFor — surge
///     helpers/cartDiscount.js      the discount is resolved server-side; here
///                                  we only APPLY an amount the caller gives.
///
/// KNOWN DIVERGENCE, deliberately not copied: the admin panel's TypeScript copy
/// (fatfox-admin-panel/src/app/_helpers/tax-calculator.ts) folds the container
/// charge INTO the taxable base. The SERVER does not — dineinBillTotal.js adds
/// `cprice` outside the GST base, after tax. We follow the server: the container
/// charge is NEVER taxed.
///
/// Pure Dart, no packages, no I/O — so it is unit-tested directly
/// (test/offline_pricing_test.dart).
library;

/// The result of pricing one dine-in bill offline.
class OfflineTotals {
  const OfflineTotals({
    required this.foodSubtotal,
    required this.areaCharge,
    required this.containerPrice,
    required this.discount,
    required this.taxTotal,
    required this.unroundedTotal,
    required this.roundOff,
    required this.total,
    required this.taxBreakdown,
    required this.isAcTaxable,
  });

  /// Base (pre-surge) food subtotal. Server: `food_subtotal`.
  final double foodSubtotal;

  /// The AC / family-room surge. Server: `area_charge`.
  final double areaCharge;

  /// Server: `container_price`. Never part of the GST base.
  final double containerPrice;

  /// Server: `discount_price`.
  final double discount;

  /// Server: `tax_price` (the sum of the breakdown).
  final double taxTotal;

  /// Server: `unrounded_total`.
  final double unroundedTotal;

  /// Server: `round_off` = total - unrounded.
  final double roundOff;

  /// Server: `total_price` = ceil(unrounded). What the guest pays.
  final double total;

  /// Display name -> amount, in the admin's configured row order.
  final List<MapEntry<String, double>> taxBreakdown;

  /// Whether the surge sat inside the GST base. It decides nothing else.
  final bool isAcTaxable;

  @override
  String toString() =>
      'OfflineTotals(food: $foodSubtotal, area: $areaCharge, container: '
      '$containerPrice, discount: $discount, tax: $taxTotal, unrounded: '
      '$unroundedTotal, roundOff: $roundOff, total: $total)';
}

/// Prices a dine-in bill exactly as `resolveDineinCartPricing` does.
class OfflinePricing {
  const OfflinePricing._();

  static const String _flat = 'flat';

  /// Round to 2 decimals. Garbage -> 0, never throws.
  ///
  /// Mirrors helpers/taxCalculator.js:21-25 `round2`
  /// (`parseFloat(parseFloat(v).toFixed(2))`).
  static double round2(Object? value) {
    final n = _toNum(value);
    if (n == null || n.isNaN) return 0;
    if (n.isInfinite) return 0;
    return double.parse(n.toStringAsFixed(2));
  }

  /// `parseFloat` semantics: numbers pass through, strings are parsed leniently
  /// (values arrive off the cached JSON as strings), anything else is null.
  static num? _toNum(Object? value) {
    if (value is num) return value;
    if (value is String) {
      final m = RegExp(r'^\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?')
          .firstMatch(value);
      if (m == null) return null;
      return double.tryParse(m.group(0)!.trim());
    }
    return null;
  }

  /// helpers/areaSurge.js:57-60 `toNumber` — finite or 0 (so `1e999` from the
  /// admin's number input can never become a bill of Infinity).
  static double _finite(Object? value) {
    final n = _toNum(value);
    if (n == null || !n.isFinite) return 0;
    return n.toDouble();
  }

  /// helpers/taxCalculator.js:38-40 — only ACTIVE components participate;
  /// `status` omitted/null means active.
  static bool _isActive(Map<String, dynamic> row) {
    final s = row['status'];
    if (s == null) return true;
    final n = _toNum(s);
    return n != null && n == 1;
  }

  /// helpers/taxCalculator.js:42-45 `rateOf` — parseFloat(value_amount), NaN->0.
  static double _rateOf(Map<String, dynamic> row) => _finite(row['value_amount']);

  /// helpers/taxCalculator.js:46 `isPct` — a STRICT `=== 'PERCENTAGE'`.
  /// Not case-folded on purpose: the server does not fold either, so a row
  /// stored as 'percentage' would be billed as FIXED by the server and must be
  /// billed as FIXED here too, or paper and ledger diverge.
  static bool _isPct(Map<String, dynamic> row) => row['value_type'] == 'PERCENTAGE';

  static String? _taxTypeOf(Map<String, dynamic> row) {
    final t = row['tax_type'];
    return t is String ? t : null;
  }

  /// helpers/taxCalculator.js:90-91 — the label the server puts on a breakdown
  /// line (`display_name`, else `tax_name`). `name` is the spelling the waiter
  /// app's own GET /restaurant/tax/settax rows use.
  static String _displayNameOf(Map<String, dynamic> row) {
    for (final k in const ['display_name', 'tax_name', 'name']) {
      final v = row[k];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    return 'Tax';
  }

  /// Price one dine-in bill.
  ///
  /// [foodSubtotal] is the sum of non-cancelled line totals, PRE-surge.
  /// [totalQuantity] is the count of non-cancelled units — a `flat` surge is
  /// per unit (helpers/areaSurge.js:145-153).
  /// [discount] is an already-resolved amount; the server revalidates the
  /// coupon itself (helpers/cartDiscount.js), so nothing is validated here.
  static OfflineTotals compute({
    required double foodSubtotal,
    required int totalQuantity,
    required List<Map<String, dynamic>> taxRows,
    Map<String, dynamic>? area,
    double containerPrice = 0,
    double discount = 0,
  }) {
    // helpers/dineinBillTotal.js:57-58
    final baseMenuTotal = round2(foodSubtotal);
    final cprice = round2(containerPrice);

    final surge = _normalizeAreaSurge(area);
    final acharge = round2(
      _areaChargeFor(baseMenuTotal, totalQuantity, surge),
    );
    final isAcTaxable = surge.isAcTaxable;

    // helpers/dineinBillTotal.js:63 — the surge joins the GST base only when
    // is_ac_taxable AND there is actually a charge.
    final taxableBase =
        (isAcTaxable && acharge > 0) ? round2(baseMenuTotal + acharge) : baseMenuTotal;

    // helpers/dineinBillTotal.js:65-74. With no tax rows the server falls into
    // its legacy arm, which (with no tax_value_amount and no legacy_tax_price)
    // yields tax 0 and grand_total == taxableBase — identical to what
    // computePickupTax returns for an empty entry list, so one path serves both.
    final gst = _computeTax(taxableBase, taxRows);

    // helpers/dineinBillTotal.js:113 — an amount, applied as given.
    final discountPrice = round2(discount);

    // helpers/dineinBillTotal.js:117-119. NOTE the container charge is added
    // HERE, outside the GST base — it is never taxed. (The admin panel's TS
    // copy folds it into the base; the server, and therefore this file, do not.)
    final unrounded = isAcTaxable
        ? _max0(round2(gst.grandTotal - discountPrice + cprice))
        : _max0(round2(gst.grandTotal - discountPrice + cprice + acharge));

    // helpers/dineinBillTotal.js:121-122
    final total = unrounded.ceil().toDouble();
    final roundOff = round2(total - unrounded);

    return OfflineTotals(
      foodSubtotal: baseMenuTotal,
      areaCharge: acharge,
      containerPrice: cprice,
      discount: discountPrice,
      taxTotal: gst.taxTotal,
      unroundedTotal: unrounded,
      roundOff: roundOff,
      total: total,
      taxBreakdown: gst.breakdown,
      isAcTaxable: isAcTaxable,
    );
  }

  static double _max0(double v) => v > 0 ? v : 0;

  // ── Area surge — helpers/areaSurge.js ──────────────────────────────────────

  /// helpers/areaSurge.js:70-87 `normalizeAreaSurge`, tolerant of every shape
  /// the floor snapshot has carried: the raw server sub-document
  /// (`price_surge_type` / `price_surge_value` / `is_ac_taxable`) and a
  /// serialized `TableArea` (lib/models/table_model.dart: surgeType/surgeValue/
  /// isAcTaxable).
  static _Surge _normalizeAreaSurge(Map<String, dynamic>? area) {
    if (area == null) return const _Surge('percentage', 0, true);

    final rawType = (area['price_surge_type'] ?? area['surgeType'] ?? 'percentage')
        .toString()
        .toLowerCase();
    final value = _finite(area['price_surge_value'] ?? area['surgeValue']);
    final rawTaxable = area.containsKey('is_ac_taxable')
        ? area['is_ac_taxable']
        : area['isAcTaxable'];
    return _Surge(
      rawType == _flat ? _flat : 'percentage',
      // A negative surge would DISCOUNT the room; no caller means that.
      value > 0 ? value : 0,
      // areaSurge.js:80-82 — false / 'false' / 0 are the only falsy spellings.
      !(rawTaxable == false || rawTaxable == 'false' || rawTaxable == 0),
    );
  }

  /// helpers/areaSurge.js:145-153 `areaChargeFor`.
  ///   flat       -> value x total quantity (PER UNIT), one rounding step.
  ///   percentage -> subtotal x value / 100.
  static double _areaChargeFor(double subtotal, int quantity, _Surge surge) {
    if (surge.value <= 0) return 0;
    if (surge.type == _flat) {
      return quantity > 0 ? round2(surge.value * quantity) : 0;
    }
    return subtotal > 0 ? round2((subtotal * surge.value) / 100) : 0;
  }

  // ── Tax — helpers/taxCalculator.js computePickupTax ────────────────────────

  /// helpers/taxCalculator.js:34-101, verbatim.
  static _Gst _computeTax(double menuTotal, List<Map<String, dynamic>> taxRows) {
    final base = round2(menuTotal);
    final entries = taxRows.where(_isActive).toList(growable: false);

    // --- Inclusive (BACKWARD): extract the net base hidden inside `base`. ---
    // taxCalculator.js:49-56
    final inclEntries =
        entries.where((e) => _taxTypeOf(e) == 'BACKWARD').toList(growable: false);
    var sumInclPct = 0.0;
    var sumInclFixed = 0.0;
    for (final e in inclEntries) {
      if (_isPct(e)) {
        sumInclPct += _rateOf(e);
      } else {
        sumInclFixed += _rateOf(e);
      }
    }
    final taxable0 = round2((base - sumInclFixed) / (1 + sumInclPct / 100));

    // The server keys these by object identity; we key by the row's position in
    // `entries`, which is the same association and survives duplicate rows.
    final inclAmount = <int, double>{};
    var sumInclTax = 0.0;
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (_taxTypeOf(e) != 'BACKWARD') continue;
      final amt =
          _isPct(e) ? round2((taxable0 * _rateOf(e)) / 100) : round2(_rateOf(e));
      inclAmount[i] = amt;
      sumInclTax = round2(sumInclTax + amt);
    }

    // taxCalculator.js:68 — reconcile so taxable + inclusive tax == base exactly.
    final taxableAmount =
        inclEntries.isNotEmpty ? round2(base - sumInclTax) : round2(base);

    // taxCalculator.js:72-95 — breakdown in the admin's configured order;
    // `accumulated` lets CALC_ON_TAX compound on the taxes before it.
    var accumulated = 0.0;
    var taxTotal = 0.0;
    final breakdown = <MapEntry<String, double>>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final type = _taxTypeOf(e);
      double taxAmount;
      if (type == 'BACKWARD') {
        taxAmount = inclAmount[i] ?? 0;
      } else if (type == 'CALC_ON_TAX') {
        taxAmount = _isPct(e)
            ? round2(((taxableAmount + accumulated) * _rateOf(e)) / 100)
            : round2(_rateOf(e));
      } else {
        // FORWARD (exclusive) — the safe default for any other value.
        taxAmount =
            _isPct(e) ? round2((taxableAmount * _rateOf(e)) / 100) : round2(_rateOf(e));
      }
      accumulated = round2(accumulated + taxAmount);
      taxTotal = round2(taxTotal + taxAmount);
      breakdown.add(MapEntry(_displayNameOf(e), taxAmount));
    }

    return _Gst(
      taxableAmount: taxableAmount,
      taxTotal: taxTotal,
      grandTotal: round2(taxableAmount + taxTotal),
      breakdown: List.unmodifiable(breakdown),
    );
  }
}

class _Surge {
  const _Surge(this.type, this.value, this.isAcTaxable);
  final String type;
  final double value;
  final bool isAcTaxable;
}

class _Gst {
  const _Gst({
    required this.taxableAmount,
    required this.taxTotal,
    required this.grandTotal,
    required this.breakdown,
  });
  final double taxableAmount;
  final double taxTotal;
  final double grandTotal;
  final List<MapEntry<String, double>> breakdown;
}
