// Golden vectors for the offline dine-in bill calculator.
//
// Every expected number below is what the api-server produces for the same
// inputs. Each vector's `derivation` comment shows the arithmetic by hand with
// the server file:line that dictates each step, so a future edit that "looks
// fine" but moves a rounding step is caught here rather than on a guest's bill.
//
// The figures were additionally cross-checked by running the REAL server
// helpers (origin/main copies of helpers/taxCalculator.js and
// helpers/areaSurge.js, driven through the exact composition of
// helpers/dineinBillTotal.js:57-122) under node v24 — every field matched.
import 'package:flutter_test/flutter_test.dart';
import 'package:dineinapk/services/offline_pricing.dart';

// ── Tax rows in the shape menu_cache_service.dart stores them ────────────────
// (tax_name / display_name / tax_type / value_type / value_amount / status),
// with value_amount as a STRING, which is how it arrives off the wire.
Map<String, dynamic> tax(
  String name,
  String taxType,
  String valueType,
  Object amount,
) => {
  'tax_name': name,
  'display_name': name,
  'tax_type': taxType,
  'value_type': valueType,
  'value_amount': '$amount',
  'status': 1,
};

final gst5 = tax('GST 5%', 'FORWARD', 'PERCENTAGE', 5);
final cgst = tax('CGST', 'FORWARD', 'PERCENTAGE', 2.5);
final sgst = tax('SGST', 'FORWARD', 'PERCENTAGE', 2.5);
final serviceFixed = tax('Service', 'FORWARD', 'FIXED', 15);
final gstIncl = tax('GST incl', 'BACKWARD', 'PERCENTAGE', 5);
final cess = tax('Cess', 'CALC_ON_TAX', 'PERCENTAGE', 10);

// ── Area rows in the shape the floor snapshot stores them ────────────────────
Map<String, dynamic> areaRow(String type, num value, {bool taxable = true}) => {
  'area_name': 'AC Hall',
  'price_surge_type': type,
  'price_surge_value': '$value',
  'is_ac_taxable': taxable,
};

class Vector {
  const Vector(
    this.name, {
    required this.foodSubtotal,
    this.totalQuantity = 0,
    this.taxRows = const [],
    this.area,
    this.containerPrice = 0,
    this.discount = 0,
    required this.expectFood,
    required this.expectArea,
    required this.expectContainer,
    required this.expectDiscount,
    required this.expectTax,
    required this.expectUnrounded,
    required this.expectRoundOff,
    required this.expectTotal,
    required this.expectBreakdown,
    required this.expectAcTaxable,
  });

  final String name;
  final double foodSubtotal;
  final int totalQuantity;
  final List<Map<String, dynamic>> taxRows;
  final Map<String, dynamic>? area;
  final double containerPrice;
  final double discount;

  final double expectFood;
  final double expectArea;
  final double expectContainer;
  final double expectDiscount;
  final double expectTax;
  final double expectUnrounded;
  final double expectRoundOff;
  final double expectTotal;
  final List<MapEntry<String, double>> expectBreakdown;
  final bool expectAcTaxable;

  OfflineTotals run() => OfflinePricing.compute(
    foodSubtotal: foodSubtotal,
    totalQuantity: totalQuantity,
    taxRows: taxRows,
    area: area,
    containerPrice: containerPrice,
    discount: discount,
  );
}

final vectors = <Vector>[
  // 1. No tax configured at all. The server's empty-entries arm leaves
  //    grand_total == taxableBase (dineinBillTotal.js:75-95), and ceil(500) is
  //    500 with no round-off (dineinBillTotal.js:121-122).
  const Vector(
    'no tax rows',
    foodSubtotal: 500,
    totalQuantity: 4,
    expectFood: 500,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 0,
    expectUnrounded: 500,
    expectRoundOff: 0,
    expectTotal: 500,
    expectBreakdown: [],
    expectAcTaxable: true,
  ),

  // 2. SERVER-DERIVED. Single 5% FORWARD GST.
  //    taxable_amount = round2(500)                      = 500.00  [taxCalculator.js:68]
  //    tax            = round2(500 * 5 / 100)            =  25.00  [taxCalculator.js:84]
  //    grand_total    = round2(500 + 25)                 = 525.00  [taxCalculator.js:99]
  //    unrounded      = max(0, round2(525 - 0 + 0))      = 525.00  [dineinBillTotal.js:117-119]
  //    total          = ceil(525.00)                     = 525     [dineinBillTotal.js:121]
  Vector(
    'single 5% forward GST',
    foodSubtotal: 500,
    totalQuantity: 4,
    taxRows: [gst5],
    expectFood: 500,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 25,
    expectUnrounded: 525,
    expectRoundOff: 0,
    expectTotal: 525,
    expectBreakdown: const [MapEntry('GST 5%', 25)],
    expectAcTaxable: true,
  ),

  // 3. SERVER-DERIVED. CGST + SGST, each rounded on its OWN line before being
  //    summed — the reason this is not simply 5% of the subtotal.
  //    CGST = round2(1234.56 * 2.5 / 100) = round2(30.864) = 30.86 [taxCalculator.js:84]
  //    SGST = same                                        = 30.86 [taxCalculator.js:84]
  //    tax_total   = round2(30.86 + 30.86)                = 61.72 [taxCalculator.js:87]
  //    grand_total = round2(1234.56 + 61.72)              = 1296.28 [taxCalculator.js:99]
  //    total       = ceil(1296.28) = 1297; round_off = round2(1297 - 1296.28)
  //                = 0.72                                          [dineinBillTotal.js:121-122]
  Vector(
    'CGST + SGST round per line',
    foodSubtotal: 1234.56,
    totalQuantity: 7,
    taxRows: [cgst, sgst],
    expectFood: 1234.56,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 61.72,
    expectUnrounded: 1296.28,
    expectRoundOff: 0.72,
    expectTotal: 1297,
    expectBreakdown: const [MapEntry('CGST', 30.86), MapEntry('SGST', 30.86)],
    expectAcTaxable: true,
  ),

  // 4. A FIXED tax is a flat amount, NOT a rate: round2(15) regardless of the
  //    subtotal [taxCalculator.js:84, the non-isPct arm].
  Vector(
    'FIXED tax is a flat amount',
    foodSubtotal: 200,
    totalQuantity: 2,
    taxRows: [serviceFixed],
    expectFood: 200,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 15,
    expectUnrounded: 215,
    expectRoundOff: 0,
    expectTotal: 215,
    expectBreakdown: const [MapEntry('Service', 15)],
    expectAcTaxable: true,
  ),

  // 5. SERVER-DERIVED. A BACKWARD (tax-inclusive) row ALONE: the 525 already
  //    contains the 5%, so it is extracted, not added.
  //    taxable0       = round2((525 - 0) / (1 + 5/100)) = round2(500) = 500.00
  //                                                        [taxCalculator.js:56]
  //    incl amount    = round2(500 * 5 / 100)           = 25.00      [taxCalculator.js:60]
  //    taxable_amount = round2(525 - 25)                = 500.00     [taxCalculator.js:68]
  //    grand_total    = round2(500 + 25)                = 525.00     [taxCalculator.js:99]
  //    => the bill does NOT grow: total stays 525.
  Vector(
    'BACKWARD (inclusive) tax alone extracts, never adds',
    foodSubtotal: 525,
    totalQuantity: 3,
    taxRows: [gstIncl],
    expectFood: 525,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 25,
    expectUnrounded: 525,
    expectRoundOff: 0,
    expectTotal: 525,
    expectBreakdown: const [MapEntry('GST incl', 25)],
    expectAcTaxable: true,
  ),

  // 6. SERVER-DERIVED. BACKWARD mixed with FORWARD. The inclusive row sets the
  //    net base (500), and the forward row is then charged ON THAT NET BASE, not
  //    on the gross 525 [taxCalculator.js:68 feeds :84].
  //    taxable_amount = 500.00; incl = 25.00; forward = round2(500*5/100) = 25.00
  //    tax_total = 50.00; grand_total = round2(500 + 50) = 550.00
  Vector(
    'BACKWARD + FORWARD: forward charges the NET base',
    foodSubtotal: 525,
    totalQuantity: 3,
    taxRows: [gstIncl, gst5],
    expectFood: 525,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 50,
    expectUnrounded: 550,
    expectRoundOff: 0,
    expectTotal: 550,
    expectBreakdown: const [MapEntry('GST incl', 25), MapEntry('GST 5%', 25)],
    expectAcTaxable: true,
  ),

  // 7. SERVER-DERIVED. CALC_ON_TAX compounds on base + the taxes BEFORE it.
  //    CGST = round2(1000 * 2.5/100) = 25.00; accumulated = 25.00
  //    SGST = round2(1000 * 2.5/100) = 25.00; accumulated = 50.00 [taxCalculator.js:86]
  //    Cess = round2((1000 + 50) * 10/100) = 105.00               [taxCalculator.js:79-81]
  //           ^ 105, NOT 100 — that extra 5.00 is the whole point of CALC_ON_TAX.
  //    tax_total = round2(25+25+105) = 155.00; grand_total = 1155.00
  Vector(
    'CALC_ON_TAX compounds on base + prior taxes',
    foodSubtotal: 1000,
    totalQuantity: 5,
    taxRows: [cgst, sgst, cess],
    expectFood: 1000,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 155,
    expectUnrounded: 1155,
    expectRoundOff: 0,
    expectTotal: 1155,
    expectBreakdown: const [
      MapEntry('CGST', 25),
      MapEntry('SGST', 25),
      MapEntry('Cess', 105),
    ],
    expectAcTaxable: true,
  ),

  // 8. Flat surge, ONE unit: value x quantity = 20 x 1 [areaSurge.js:147-149].
  //    taxable base = round2(300 + 20) = 320 [dineinBillTotal.js:63]
  //    tax = round2(320 * 5/100) = 16.00; grand = 336.00
  Vector(
    'flat surge, 1 unit',
    foodSubtotal: 300,
    totalQuantity: 1,
    taxRows: [gst5],
    area: {
      'area_name': 'AC Hall',
      'price_surge_type': 'flat',
      'price_surge_value': '20',
      'is_ac_taxable': true,
    },
    expectFood: 300,
    expectArea: 20,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 16,
    expectUnrounded: 336,
    expectRoundOff: 0,
    expectTotal: 336,
    expectBreakdown: const [MapEntry('GST 5%', 16)],
    expectAcTaxable: true,
  ),

  // 9. SERVER-DERIVED. The SAME flat surge on THREE units is 60, not 20 —
  //    flat is PER UNIT [areaSurge.js:145-149; the bug that helper was written
  //    to end]. taxable base = round2(300 + 60) = 360; tax = 18.00; total 378.
  Vector(
    'flat surge is PER UNIT (3 units)',
    foodSubtotal: 300,
    totalQuantity: 3,
    taxRows: [gst5],
    area: {
      'area_name': 'AC Hall',
      'price_surge_type': 'flat',
      'price_surge_value': '20',
      'is_ac_taxable': true,
    },
    expectFood: 300,
    expectArea: 60,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 18,
    expectUnrounded: 378,
    expectRoundOff: 0,
    expectTotal: 378,
    expectBreakdown: const [MapEntry('GST 5%', 18)],
    expectAcTaxable: true,
  ),

  // 10. Percentage surge is a share of the SUBTOTAL, quantity-independent
  //     [areaSurge.js:151-152]: round2(800 * 10/100) = 80.
  //     taxable = 880; tax = 44.00; total 924.
  Vector(
    'percentage surge is on the subtotal',
    foodSubtotal: 800,
    totalQuantity: 6,
    taxRows: [gst5],
    area: {
      'area_name': 'AC Hall',
      'price_surge_type': 'percentage',
      'price_surge_value': '10',
      'is_ac_taxable': true,
    },
    expectFood: 800,
    expectArea: 80,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 44,
    expectUnrounded: 924,
    expectRoundOff: 0,
    expectTotal: 924,
    expectBreakdown: const [MapEntry('GST 5%', 44)],
    expectAcTaxable: true,
  ),

  // 11. SERVER-DERIVED. The SAME surge with is_ac_taxable FALSE. The charge is
  //     identical (80) — is_ac_taxable never changes the surge itself
  //     [areaSurge.js:30-33] — but it now sits OUTSIDE the GST base:
  //     taxable = 800; tax = round2(800*5/100) = 40.00 (not 44);
  //     unrounded = round2(840 - 0 + 0 + 80) = 920.00 [dineinBillTotal.js:119].
  Vector(
    'is_ac_taxable false: same surge, outside the GST base',
    foodSubtotal: 800,
    totalQuantity: 6,
    taxRows: [gst5],
    area: {
      'area_name': 'AC Hall',
      'price_surge_type': 'percentage',
      'price_surge_value': '10',
      'is_ac_taxable': false,
    },
    expectFood: 800,
    expectArea: 80,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 40,
    expectUnrounded: 920,
    expectRoundOff: 0,
    expectTotal: 920,
    expectBreakdown: const [MapEntry('GST 5%', 40)],
    expectAcTaxable: false,
  ),

  // 12. Container charge with NO tax rows: it is simply added.
  const Vector(
    'container charge, no tax rows',
    foodSubtotal: 500,
    totalQuantity: 4,
    containerPrice: 30,
    expectFood: 500,
    expectArea: 0,
    expectContainer: 30,
    expectDiscount: 0,
    expectTax: 0,
    expectUnrounded: 530,
    expectRoundOff: 0,
    expectTotal: 530,
    expectBreakdown: [],
    expectAcTaxable: true,
  ),

  // 13. SERVER-DERIVED — THE DIVERGENCE VECTOR. Container charge WITH a tax row.
  //     The server adds `cprice` at dineinBillTotal.js:117-119, i.e. AFTER
  //     computePickupTax, so it is NEVER in the GST base:
  //       tax = round2(500 * 5/100) = 25.00   (500, not 530)
  //       unrounded = round2(525 - 0 + 30) = 555.00
  //     The admin panel's tax-calculator.ts folds the container into the base,
  //     which would give tax = round2(530*5/100) = 26.50 and a total of 556.50
  //     -> 557. That number is WRONG for this app; the server wins.
  Vector(
    'container charge is NEVER taxed (server, not admin-panel, rule)',
    foodSubtotal: 500,
    totalQuantity: 4,
    taxRows: [gst5],
    containerPrice: 30,
    expectFood: 500,
    expectArea: 0,
    expectContainer: 30,
    expectDiscount: 0,
    expectTax: 25,
    expectUnrounded: 555,
    expectRoundOff: 0,
    expectTotal: 555,
    expectBreakdown: const [MapEntry('GST 5%', 25)],
    expectAcTaxable: true,
  ),

  // 14. A discount is subtracted AFTER tax, off the grand total
  //     [dineinBillTotal.js:117]: tax is still round2(1000*5/100) = 50 — the
  //     discount does not shrink the taxable base. 1050 - 100 = 950.
  Vector(
    'discount is subtracted after tax',
    foodSubtotal: 1000,
    totalQuantity: 5,
    taxRows: [gst5],
    discount: 100,
    expectFood: 1000,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 100,
    expectTax: 50,
    expectUnrounded: 950,
    expectRoundOff: 0,
    expectTotal: 950,
    expectBreakdown: const [MapEntry('GST 5%', 50)],
    expectAcTaxable: true,
  ),

  // 15. SERVER-DERIVED. A fractional subtotal, to pin the ceil + round_off pair.
  //     CGST = round2(333.33 * 2.5/100) = round2(8.333...) = 8.33
  //     SGST = 8.33; tax_total = 16.66; grand = round2(333.33 + 16.66) = 349.99
  //     total = ceil(349.99) = 350; round_off = round2(350 - 349.99) = 0.01
  //     [dineinBillTotal.js:121-122]
  Vector(
    'fractional subtotal: total == ceil(unrounded)',
    foodSubtotal: 333.33,
    totalQuantity: 3,
    taxRows: [cgst, sgst],
    expectFood: 333.33,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 16.66,
    expectUnrounded: 349.99,
    expectRoundOff: 0.01,
    expectTotal: 350,
    expectBreakdown: const [MapEntry('CGST', 8.33), MapEntry('SGST', 8.33)],
    expectAcTaxable: true,
  ),

  // 16. SERVER-DERIVED. Everything at once, with a NON-taxable flat surge.
  //     area   = round2(12.5 * 7)               = 87.50   [areaSurge.js:149]
  //     taxable base = 1234.56 (surge excluded) [dineinBillTotal.js:63]
  //     CGST = SGST = round2(1234.56*2.5/100)   = 30.86
  //     Cess = round2((1234.56 + 61.72)*10/100) = round2(129.628) = 129.63
  //     tax_total = round2(30.86+30.86+129.63)  = 191.35
  //     grand     = round2(1234.56 + 191.35)    = 1425.91
  //     unrounded = round2(1425.91 - 75 + 25 + 87.50) = 1463.41 [dineinBillTotal.js:119]
  //     total = ceil(1463.41) = 1464; round_off = round2(1464 - 1463.41) = 0.59
  Vector(
    'everything at once: surge + compound tax + container + discount',
    foodSubtotal: 1234.56,
    totalQuantity: 7,
    taxRows: [cgst, sgst, cess],
    area: {
      'price_surge_type': 'flat',
      'price_surge_value': '12.5',
      'is_ac_taxable': false,
    },
    containerPrice: 25,
    discount: 75,
    expectFood: 1234.56,
    expectArea: 87.5,
    expectContainer: 25,
    expectDiscount: 75,
    expectTax: 191.35,
    expectUnrounded: 1463.41,
    expectRoundOff: 0.59,
    expectTotal: 1464,
    expectBreakdown: const [
      MapEntry('CGST', 30.86),
      MapEntry('SGST', 30.86),
      MapEntry('Cess', 129.63),
    ],
    expectAcTaxable: false,
  ),

  // 17. An empty table: every figure zero, and the configured row still appears
  //     in the breakdown at 0 (the server maps EVERY active entry).
  Vector(
    'zero / empty cart',
    foodSubtotal: 0,
    totalQuantity: 0,
    taxRows: [gst5],
    expectFood: 0,
    expectArea: 0,
    expectContainer: 0,
    expectDiscount: 0,
    expectTax: 0,
    expectUnrounded: 0,
    expectRoundOff: 0,
    expectTotal: 0,
    expectBreakdown: const [MapEntry('GST 5%', 0)],
    expectAcTaxable: true,
  ),
];

void main() {
  group('OfflinePricing.compute — golden vectors vs the api-server', () {
    for (final v in vectors) {
      test(v.name, () {
        final t = v.run();
        expect(t.foodSubtotal, v.expectFood, reason: 'food_subtotal');
        expect(t.areaCharge, v.expectArea, reason: 'area_charge');
        expect(t.containerPrice, v.expectContainer, reason: 'container_price');
        expect(t.discount, v.expectDiscount, reason: 'discount_price');
        expect(t.taxTotal, v.expectTax, reason: 'tax_price');
        expect(t.unroundedTotal, v.expectUnrounded, reason: 'unrounded_total');
        expect(t.roundOff, v.expectRoundOff, reason: 'round_off');
        expect(t.total, v.expectTotal, reason: 'total_price');
        expect(t.isAcTaxable, v.expectAcTaxable, reason: 'is_ac_taxable');
        expect(
          t.taxBreakdown.map((e) => '${e.key}=${e.value}').toList(),
          v.expectBreakdown.map((e) => '${e.key}=${e.value}').toList(),
          reason: 'tax_breakdown (display name -> amount, in config order)',
        );
      });
    }
  });

  // ── Invariants the vectors above should never be allowed to lose ───────────
  group('invariants', () {
    test('total is always ceil(unrounded) and roundOff closes the gap', () {
      for (final v in vectors) {
        final t = v.run();
        expect(
          t.total,
          t.unroundedTotal.ceil().toDouble(),
          reason: '${v.name}: total must be ceil(unrounded) '
              '[dineinBillTotal.js:121]',
        );
        expect(
          t.roundOff,
          OfflinePricing.round2(t.total - t.unroundedTotal),
          reason: '${v.name}: round_off = round2(total - unrounded) '
              '[dineinBillTotal.js:122]',
        );
        expect(t.roundOff, greaterThanOrEqualTo(0));
        expect(t.roundOff, lessThan(1));
      }
    });

    test('the tax breakdown always sums to taxTotal', () {
      for (final v in vectors) {
        final t = v.run();
        var sum = 0.0;
        for (final e in t.taxBreakdown) {
          sum = OfflinePricing.round2(sum + e.value);
        }
        expect(sum, t.taxTotal, reason: v.name);
      }
    });

    test(
      'the container charge never changes the tax — the SERVER rule '
      '(dineinBillTotal.js:117-119 adds cprice outside the GST base, unlike '
      'fatfox-admin-panel/src/app/_helpers/tax-calculator.ts)',
      () {
        for (final container in [0.0, 30.0, 999.99]) {
          final t = OfflinePricing.compute(
            foodSubtotal: 500,
            totalQuantity: 4,
            taxRows: [gst5],
            containerPrice: container,
          );
          expect(t.taxTotal, 25, reason: 'container $container must not be taxed');
          expect(t.unroundedTotal, OfflinePricing.round2(525 + container));
        }
      },
    );

    test('a discount can never drive the bill below zero '
        '[dineinBillTotal.js:117, Math.max(0, ...)]', () {
      final t = OfflinePricing.compute(
        foodSubtotal: 100,
        totalQuantity: 1,
        taxRows: [gst5],
        discount: 5000,
      );
      expect(t.unroundedTotal, 0);
      expect(t.total, 0);
      expect(t.roundOff, 0);
    });
  });

  group('input coercion (cached rows arrive as strings)', () {
    test('string value_amount prices identically to a numeric one', () {
      final asString = OfflinePricing.compute(
        foodSubtotal: 500,
        totalQuantity: 1,
        taxRows: [
          {
            'display_name': 'GST 5%',
            'tax_type': 'FORWARD',
            'value_type': 'PERCENTAGE',
            'value_amount': '5',
          },
        ],
      );
      final asNumber = OfflinePricing.compute(
        foodSubtotal: 500,
        totalQuantity: 1,
        taxRows: [
          {
            'display_name': 'GST 5%',
            'tax_type': 'FORWARD',
            'value_type': 'PERCENTAGE',
            'value_amount': 5,
          },
        ],
      );
      expect(asString.taxTotal, 25);
      expect(asNumber.taxTotal, 25);
    });

    test('an inactive row (status 0) does not participate '
        '[taxCalculator.js:38-40]', () {
      final t = OfflinePricing.compute(
        foodSubtotal: 500,
        totalQuantity: 1,
        taxRows: [
          {...gst5, 'status': 0},
        ],
      );
      expect(t.taxTotal, 0);
      expect(t.taxBreakdown, isEmpty);
      expect(t.total, 500);
    });

    test('a row with no status is ACTIVE [taxCalculator.js:39]', () {
      final t = OfflinePricing.compute(
        foodSubtotal: 500,
        totalQuantity: 1,
        taxRows: [
          {
            'display_name': 'GST 5%',
            'tax_type': 'FORWARD',
            'value_type': 'PERCENTAGE',
            'value_amount': '5',
          },
        ],
      );
      expect(t.taxTotal, 25);
    });

    test('a null area means no surge, taxable by default '
        '[areaSurge.js:71-73]', () {
      final t = OfflinePricing.compute(
        foodSubtotal: 500,
        totalQuantity: 9,
        taxRows: [gst5],
      );
      expect(t.areaCharge, 0);
      expect(t.isAcTaxable, isTrue);
    });

    test('a negative surge never discounts the room [areaSurge.js:79]', () {
      final t = OfflinePricing.compute(
        foodSubtotal: 500,
        totalQuantity: 3,
        taxRows: const [],
        area: areaRow('flat', -50),
      );
      expect(t.areaCharge, 0);
      expect(t.total, 500);
    });

    test('a non-finite surge can never produce a bill of Infinity '
        '[areaSurge.js:57-60]', () {
      final t = OfflinePricing.compute(
        foodSubtotal: 500,
        totalQuantity: 3,
        taxRows: const [],
        area: {'price_surge_type': 'flat', 'price_surge_value': '1e999'},
      );
      expect(t.areaCharge, 0);
      expect(t.total, 500);
    });

    test("is_ac_taxable accepts the string 'false' and 0 "
        '[areaSurge.js:80-82]', () {
      for (final falsy in <Object>[false, 'false', 0]) {
        final t = OfflinePricing.compute(
          foodSubtotal: 800,
          totalQuantity: 1,
          taxRows: [gst5],
          area: {
            'price_surge_type': 'percentage',
            'price_surge_value': '10',
            'is_ac_taxable': falsy,
          },
        );
        expect(t.isAcTaxable, isFalse, reason: 'falsy spelling: $falsy');
        expect(t.taxTotal, 40, reason: 'surge stays out of the GST base');
        expect(t.total, 920);
      }
    });

    test('a serialized TableArea (camelCase) prices like the raw area row', () {
      final raw = OfflinePricing.compute(
        foodSubtotal: 300,
        totalQuantity: 3,
        taxRows: [gst5],
        area: areaRow('flat', 20),
      );
      final camel = OfflinePricing.compute(
        foodSubtotal: 300,
        totalQuantity: 3,
        taxRows: [gst5],
        area: {'surgeType': 'flat', 'surgeValue': 20, 'isAcTaxable': true},
      );
      expect(camel.areaCharge, raw.areaCharge);
      expect(camel.total, raw.total);
    });

    test('the breakdown label falls back display_name -> tax_name -> name', () {
      final t = OfflinePricing.compute(
        foodSubtotal: 100,
        totalQuantity: 1,
        taxRows: [
          {
            'name': 'Legacy GST',
            'tax_type': 'FORWARD',
            'value_type': 'PERCENTAGE',
            'value_amount': '5',
          },
        ],
      );
      expect(t.taxBreakdown.single.key, 'Legacy GST');
    });
  });
}
