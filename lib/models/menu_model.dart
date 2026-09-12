class MenuCategory {
  final String id;
  final String categoryName;
  final String? image;
  final int count;

  MenuCategory({
    required this.id,
    required this.categoryName,
    this.image,
    this.count = 0,
  });

  factory MenuCategory.fromJson(Map<String, dynamic> json) {
    return MenuCategory(
      id: json['_id']?.toString() ?? '',
      categoryName: json['category_name']?.toString() ?? 'Category',
      image: json['image']?.toString(),
      count: int.tryParse(json['count']?.toString() ?? '0') ?? 0,
    );
  }
}

class MenuVariant {
  final String id;
  final String name;
  final double price;

  MenuVariant({required this.id, required this.name, required this.price});

  factory MenuVariant.fromJson(Map<String, dynamic> json) {
    return MenuVariant(
      id:
          json['_id']?.toString() ??
          json['variant_id']?.toString() ??
          json['value_id']?.toString() ??
          '',
      name: json['valuename']?.toString() ?? json['name']?.toString() ?? '',
      price: double.tryParse(json['price']?.toString() ?? '0') ?? 0.0,
    );
  }
}

class MenuAddon {
  final String addonId;
  final String id;
  final String name;
  final String valueName;
  final double price;

  MenuAddon({
    required this.addonId,
    required this.id,
    required this.name,
    required this.valueName,
    required this.price,
  });

  factory MenuAddon.fromJson(Map<String, dynamic> json) {
    final value = json['value'] is Map<String, dynamic>
        ? json['value'] as Map<String, dynamic>
        : null;
    return MenuAddon(
      addonId: json['addon_id']?.toString() ?? '',
      id:
          json['addonvalue_id']?.toString() ??
          json['value_id']?.toString() ??
          value?['_id']?.toString() ??
          json['_id']?.toString() ??
          '',
      name: json['name']?.toString() ?? '',
      valueName:
          json['valuename']?.toString() ??
          json['value_name']?.toString() ??
          value?['valuename']?.toString() ??
          value?['name']?.toString() ??
          '',
      price:
          double.tryParse(
            json['addon_price']?.toString() ??
                json['price']?.toString() ??
                value?['price']?.toString() ??
                '0',
          ) ??
          0.0,
    );
  }

  Map<String, dynamic> toCartAddonJson() {
    return {
      'addon_id': addonId,
      'addonvalue_id': id,
      'addon_price': price,
      'value': {'_id': id, 'valuename': valueName, 'price': price},
    };
  }
}

class MenuItem {
  final String id;
  final String categoryId;
  final String name;
  final String? displayName;
  final String? shortCode;
  final String attribute; // 'VEG', 'NONVEG', 'EGG'
  final double price;
  final String? image;
  final List<MenuVariant> variants;
  final List<MenuAddon> addons;

  bool get hasVariants => variants.isNotEmpty;
  bool get hasAddons => addons.isNotEmpty;

  MenuItem({
    required this.id,
    required this.categoryId,
    required this.name,
    this.displayName,
    this.shortCode,
    required this.attribute,
    required this.price,
    this.image,
    this.variants = const [],
    this.addons = const [],
  });

  factory MenuItem.fromJson(Map<String, dynamic> json) {
    bool isActive(dynamic status) =>
        status == null || status == 1 || status == '1';

    final varList = <MenuVariant>[];
    if (json['variants'] is List) {
      for (var v in (json['variants'] as List)) {
        if (v is Map<String, dynamic> && isActive(v['status'])) {
          varList.add(MenuVariant.fromJson(v));
        }
      }
    }

    final addList = <MenuAddon>[];
    if (json['addons'] is List) {
      for (var a in (json['addons'] as List)) {
        if (a is Map<String, dynamic>) {
          addList.add(MenuAddon.fromJson(a));
        }
      }
    }
    if (json['addOns'] is List) {
      for (var group in (json['addOns'] as List)) {
        if (group is Map<String, dynamic>) {
          final addonId =
              group['addon_id']?.toString() ?? group['_id']?.toString() ?? '';
          final values = group['value'];
          if (values is List) {
            for (var value in values) {
              if (value is Map<String, dynamic> && isActive(value['status'])) {
                addList.add(
                  MenuAddon.fromJson({
                    ...value,
                    'addon_id': addonId,
                    'name': group['displayname'] ?? group['name'],
                  }),
                );
              }
            }
          } else {
            addList.add(MenuAddon.fromJson(group));
          }
        }
      }
    }

    return MenuItem(
      id: json['_id']?.toString() ?? '',
      categoryId: json['category_id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Menu Item',
      displayName: json['displayname']?.toString(),
      shortCode:
          json['shortCode']?.toString() ?? json['short_code']?.toString(),
      attribute: (json['attribute']?.toString() ?? 'VEG').toUpperCase(),
      price: double.tryParse(json['price']?.toString() ?? '0') ?? 0.0,
      image: json['image']?.toString(),
      variants: varList,
      addons: addList,
    );
  }
}
