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
      id: json['_id']?.toString() ?? json['value_id']?.toString() ?? '',
      name: json['valuename']?.toString() ?? json['name']?.toString() ?? '',
      price: double.tryParse(json['price']?.toString() ?? '0') ?? 0.0,
    );
  }
}

class MenuAddon {
  final String id;
  final String name;
  final String valueName;
  final double price;

  MenuAddon({
    required this.id,
    required this.name,
    required this.valueName,
    required this.price,
  });

  factory MenuAddon.fromJson(Map<String, dynamic> json) {
    return MenuAddon(
      id: json['_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      valueName: json['valuename']?.toString() ?? json['value_name']?.toString() ?? '',
      price: double.tryParse(json['price']?.toString() ?? '0') ?? 0.0,
    );
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
    final varList = <MenuVariant>[];
    if (json['variants'] is List) {
      for (var v in (json['variants'] as List)) {
        if (v is Map<String, dynamic>) {
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

    return MenuItem(
      id: json['_id']?.toString() ?? '',
      categoryId: json['category_id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Menu Item',
      displayName: json['displayname']?.toString(),
      shortCode: json['shortCode']?.toString() ?? json['short_code']?.toString(),
      attribute: (json['attribute']?.toString() ?? 'VEG').toUpperCase(),
      price: double.tryParse(json['price']?.toString() ?? '0') ?? 0.0,
      image: json['image']?.toString(),
      variants: varList,
      addons: addList,
    );
  }
}
