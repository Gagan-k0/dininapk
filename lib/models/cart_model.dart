import 'menu_model.dart';

class CartLineItem {
  final String id;
  final MenuItem item;
  int quantity;
  MenuVariant? selectedVariant;
  List<MenuAddon> selectedAddons;
  String? instruction;
  bool isKotPrinted;
  int cancelStatus; // 0 = active, 1 = cancelled

  CartLineItem({
    required this.id,
    required this.item,
    this.quantity = 1,
    this.selectedVariant,
    this.selectedAddons = const [],
    this.instruction,
    this.isKotPrinted = false,
    this.cancelStatus = 0,
  });

  double get unitPrice => selectedVariant != null ? selectedVariant!.price : item.price;
  double get addonsTotal => selectedAddons.fold(0.0, (sum, a) => sum + a.price);
  double get lineTotal => (unitPrice + addonsTotal) * quantity;

  Map<String, dynamic> toCartJson() {
    return {
      'menu_id': item.id,
      'quantity': quantity,
      'price': lineTotal,
      'menu_price': unitPrice,
      'variant_id': selectedVariant?.id,
      'addons': selectedAddons.map((a) => {'addon_id': a.id, 'price': a.price}).toList(),
      'description': instruction ?? '',
    };
  }
}

class OrderTax {
  final String id;
  final String taxName;
  final double taxPercent;

  OrderTax({
    required this.id,
    required this.taxName,
    required this.taxPercent,
  });

  factory OrderTax.fromJson(Map<String, dynamic> json) {
    return OrderTax(
      id: json['_id']?.toString() ?? '',
      taxName: json['tax_name']?.toString() ?? json['name']?.toString() ?? 'Tax',
      taxPercent: double.tryParse(json['value_amount']?.toString() ?? json['tax_price']?.toString() ?? '0') ?? 0.0,
    );
  }
}
