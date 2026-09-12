class TableArea {
  final String id;
  final String name;

  TableArea({required this.id, required this.name});

  factory TableArea.fromJson(Map<String, dynamic> json) {
    return TableArea(
      id: json['_id']?.toString() ?? '',
      name: json['name']?.toString() ?? json['area_name']?.toString() ?? '',
    );
  }
}

class DineInTable {
  final String id;
  final String tableNumber;
  final String areaId;
  final int noOfPeople;
  final String tableStatus; // 'BLANK', 'PENDING', 'KOT', 'KOT_PRINT', 'PRINTED', 'PAID'
  final String status;
  final double totalPrice;
  final int itemCount;
  final String? createdAt;
  final Map<String, dynamic>? cartDetails;

  DineInTable({
    required this.id,
    required this.tableNumber,
    required this.areaId,
    required this.noOfPeople,
    required this.tableStatus,
    required this.status,
    required this.totalPrice,
    required this.itemCount,
    this.createdAt,
    this.cartDetails,
  });

  bool get isAvailable => tableStatus == 'BLANK' && cartDetails == null;
  bool get isOccupied => !isAvailable;
  bool get isPending => tableStatus == 'PENDING';
  bool get isKot => tableStatus == 'KOT' || tableStatus == 'KOT_PRINT';
  bool get isPrinted => tableStatus == 'PRINTED';

  factory DineInTable.fromJson(Map<String, dynamic> json) {
    final cart = json['cart_details'] as Map<String, dynamic>?;
    double price = 0.0;
    if (cart != null && cart['total_price'] != null) {
      price = double.tryParse(cart['total_price'].toString()) ?? 0.0;
    } else if (json['total_price'] != null) {
      price = double.tryParse(json['total_price'].toString()) ?? 0.0;
    }

    int items = 0;
    if (json['cartmenu'] is List) {
      items = (json['cartmenu'] as List).length;
    } else if (cart != null && cart['cartMenuData'] is List) {
      items = (cart['cartMenuData'] as List).length;
    }

    return DineInTable(
      id: json['_id']?.toString() ?? json['table_id']?.toString() ?? '',
      tableNumber: json['table_number']?.toString() ?? '0',
      areaId: json['area_id']?.toString() ?? '',
      noOfPeople: int.tryParse(json['no_of_people']?.toString() ?? '4') ?? 4,
      tableStatus: json['table_status']?.toString() ?? 'BLANK',
      status: json['status']?.toString() ?? 'available',
      totalPrice: price,
      itemCount: items,
      createdAt: json['createdAt']?.toString(),
      cartDetails: cart,
    );
  }
}
