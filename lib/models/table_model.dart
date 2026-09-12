class TableArea {
  final String id;
  final String name;

  /// Area surge rule (admin oracle: `flat` is PER UNIT, `percentage` is a share
  /// of each unit price; `is_ac_taxable` only decides whether the surge sits
  /// inside the GST base). Kept for display — the server recomputes the charge
  /// on every cart write.
  final String surgeType; // 'flat' | 'percentage'
  final double surgeValue;
  final bool isAcTaxable;

  TableArea({
    required this.id,
    required this.name,
    this.surgeType = 'percentage',
    this.surgeValue = 0,
    this.isAcTaxable = true,
  });

  factory TableArea.fromJson(Map<String, dynamic> json) {
    final rawTaxable = json['is_ac_taxable'];
    return TableArea(
      id: json['_id']?.toString() ?? '',
      name: json['name']?.toString() ?? json['area_name']?.toString() ?? '',
      surgeType:
          (json['price_surge_type']?.toString() ?? 'percentage').toLowerCase() ==
                  'flat'
              ? 'flat'
              : 'percentage',
      surgeValue:
          double.tryParse(json['price_surge_value']?.toString() ?? '0') ?? 0,
      isAcTaxable:
          !(rawTaxable == false || rawTaxable == 'false' || rawTaxable == 0),
    );
  }
}

/// One row of `GET /restaurant/table/all`.
///
/// `table_status` comes from the live cart (`BLANK` when there is none). A
/// table can be `BLANK` yet still carry `cart_details` (items added, nothing
/// sent to the kitchen) — that is OCCUPIED, exactly as on the admin floor.
class DineInTable {
  final String id;
  final String tableNumber;
  final String areaId;
  final String areaName;
  final int noOfPeople;
  final String tableStatus; // BLANK | PENDING | RUNNING | KOT | KOT_PRINT | PRINTED | PAID
  final String status;
  final double totalPrice;
  final int itemCount;
  final String? createdAt;
  final Map<String, dynamic>? cartDetails;
  final String? cartId;
  final String dineinType; // '' | 'Dine In' | 'QR Dine-In' | 'Pre Booking'
  final Map<String, dynamic>? reservation;
  final bool combinable;
  final List<String> combinableTableIds;

  DineInTable({
    required this.id,
    required this.tableNumber,
    required this.areaId,
    this.areaName = '',
    required this.noOfPeople,
    required this.tableStatus,
    required this.status,
    required this.totalPrice,
    required this.itemCount,
    this.createdAt,
    this.cartDetails,
    this.cartId,
    this.dineinType = '',
    this.reservation,
    this.combinable = true,
    this.combinableTableIds = const [],
  });

  bool get isAvailable => tableStatus == 'BLANK' && cartDetails == null;
  bool get isOccupied => !isAvailable;
  bool get isPending => tableStatus == 'PENDING';
  bool get isKot => tableStatus == 'KOT' || tableStatus == 'KOT_PRINT';
  bool get isPrinted => tableStatus == 'PRINTED';
  bool get isPaid => tableStatus == 'PAID';

  /// Admin floor rule: Release (settle) only once the bill has been printed.
  bool get canRelease => isPrinted || isPaid;

  /// Booking-backed sitting (admin `isPreBooking`).
  bool get isPreBooking => dineinType == 'Pre Booking' || reservation != null;

  bool get isCombined => combinableTableIds.isNotEmpty;

  String? get customerName {
    final n = cartDetails?['customer_name']?.toString();
    return (n == null || n.isEmpty) ? null : n;
  }

  /// Minutes since the cart was created (admin derives this from the cart
  /// `_id` ObjectId timestamp, capped at 2 days). Null when there is no cart.
  int? get seatedMinutes {
    final ts = objectIdTimestamp(cartId) ??
        DateTime.tryParse(cartDetails?['createdAt']?.toString() ?? '');
    if (ts == null) return null;
    final mins = DateTime.now().toUtc().difference(ts.toUtc()).inMinutes;
    if (mins < 0) return 0;
    return mins > 2880 ? 2880 : mins;
  }

  /// "12m" / "1h 05m" for the card.
  String? get seatedLabel {
    final m = seatedMinutes;
    if (m == null) return null;
    if (m < 60) return '${m}m';
    final h = m ~/ 60;
    final r = m % 60;
    return '${h}h ${r.toString().padLeft(2, '0')}m';
  }

  static DateTime? objectIdTimestamp(String? id) {
    if (id == null || id.length != 24) return null;
    final secs = int.tryParse(id.substring(0, 8), radix: 16);
    if (secs == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
  }

  factory DineInTable.fromJson(Map<String, dynamic> json) {
    // API may return null or a plain ObjectId string — never cast blindly.
    final rawCart = json['cart_details'] ?? json['cartDetails'];
    final Map<String, dynamic>? cart =
        rawCart is Map ? Map<String, dynamic>.from(rawCart) : null;

    double price = 0.0;
    if (cart != null && cart['total_price'] != null) {
      price = double.tryParse(cart['total_price'].toString()) ?? 0.0;
    } else if (json['total_price'] != null) {
      price = double.tryParse(json['total_price'].toString()) ?? 0.0;
    }

    int items = 0;
    if (json['cartmenu'] is List) {
      items = (json['cartmenu'] as List)
          .where((m) => m is Map && m['cancel_status'] != 1)
          .length;
    } else if (cart != null && cart['cartMenuData'] is List) {
      items = (cart['cartMenuData'] as List).length;
    }

    final rawArea = json['area_id'] ?? json['area'];
    final areaId = rawArea is Map
        ? (rawArea['_id'] ?? rawArea['id'])?.toString() ?? ''
        : rawArea?.toString() ?? '';
    final areaDoc = json['area'];
    final areaName = areaDoc is Map
        ? (areaDoc['area_name'] ?? areaDoc['name'])?.toString() ?? ''
        : '';

    final rawCartId = json['cart_id'] ?? cart?['_id'] ?? cart?['cart_id'];
    final cartId = rawCartId is Map
        ? rawCartId['_id']?.toString()
        : rawCartId?.toString();

    final rawRes = json['reservation'];
    final reservation =
        rawRes is Map ? Map<String, dynamic>.from(rawRes) : null;

    final rawCombinable = json['combinable'];
    final combinable = !(rawCombinable == false ||
        rawCombinable == 'false' ||
        rawCombinable == 0);
    final combIds = (json['combinable_table_ids'] is List)
        ? (json['combinable_table_ids'] as List)
            .map((e) => e is Map ? e['_id']?.toString() ?? '' : e.toString())
            .where((e) => e.isNotEmpty)
            .toList()
        : const <String>[];

    return DineInTable(
      id: json['_id']?.toString() ??
          (json['table_id'] is Map
              ? json['table_id']['_id']?.toString()
              : json['table_id']?.toString()) ??
          '',
      tableNumber: json['table_number']?.toString() ??
          json['table_no']?.toString() ??
          '0',
      areaId: areaId,
      areaName: areaName,
      noOfPeople: int.tryParse(json['no_of_people']?.toString() ?? '4') ?? 4,
      tableStatus: json['table_status']?.toString() ??
          cart?['table_status']?.toString() ??
          'BLANK',
      status: json['status']?.toString() ?? 'available',
      totalPrice: price,
      itemCount: items,
      createdAt: json['createdAt']?.toString(),
      cartDetails: cart,
      cartId: (cartId == null || cartId.isEmpty) ? null : cartId,
      dineinType: json['dinein_type']?.toString() ?? '',
      reservation: reservation,
      combinable: combinable,
      combinableTableIds: combIds,
    );
  }
}
