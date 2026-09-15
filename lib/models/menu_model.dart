/// Flatten one nesting level of `category` from by-category-itemin.
List<String> flattenCategoryNames(dynamic categoryField) {
  if (categoryField is! List) return <String>[];
  final flat = <dynamic>[];
  for (final c in categoryField) {
    if (c is List) {
      flat.addAll(c);
    } else {
      flat.add(c);
    }
  }
  final names = <String>[];
  for (final c in flat) {
    if (c is Map) {
      final name = c['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) names.add(name);
    }
  }
  return names;
}

List<String> flattenCategoryIds(dynamic categoryField) {
  if (categoryField is! List) return <String>[];
  final flat = <dynamic>[];
  for (final c in categoryField) {
    if (c is List) {
      flat.addAll(c);
    } else {
      flat.add(c);
    }
  }
  final ids = <String>[];
  for (final c in flat) {
    if (c is Map) {
      final id = c['_id']?.toString() ?? c['category_id']?.toString() ?? '';
      if (id.isNotEmpty) ids.add(id);
    } else if (c != null) {
      final id = c.toString();
      if (id.isNotEmpty && id != 'null') ids.add(id);
    }
  }
  return ids;
}

class MenuCategory {
  final String id;
  final String categoryName;
  final String? valueName;
  final String? displayName;
  final String? image;
  final int count;

  MenuCategory({
    required this.id,
    required this.categoryName,
    this.valueName,
    this.displayName,
    this.image,
    this.count = 0,
  });

  /// Names used by admin `filterCachedDineinMenu` ([valuename, displayname, name]).
  List<String> get filterNames {
    final out = <String>[];
    void add(String? v) {
      final t = v?.trim() ?? '';
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }

    add(valueName);
    add(displayName);
    add(categoryName);
    return out;
  }

  factory MenuCategory.fromJson(Map<String, dynamic> json) {
    final valueName = json['valuename']?.toString();
    final displayName = json['displayname']?.toString();
    final legacy = json['category_name']?.toString();
    final label = () {
      for (final v in [displayName, valueName, legacy]) {
        if (v != null && v.trim().isNotEmpty) return v.trim();
      }
      return 'Category';
    }();

    return MenuCategory(
      id: json['_id']?.toString() ?? '',
      categoryName: label,
      valueName: valueName,
      displayName: displayName,
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

/// `name` in API payloads is sometimes `""` while `displayname` holds the title.
String _parseMenuName(Map<String, dynamic> json) {
  final name = json['name']?.toString().trim() ?? '';
  if (name.isNotEmpty) return name;
  final display = json['displayname']?.toString().trim() ?? '';
  if (display.isNotEmpty) return display;
  final code = json['shortCode']?.toString().trim() ??
      json['short_code']?.toString().trim() ??
      '';
  if (code.isNotEmpty) return code;
  return 'Menu Item';
}

class MenuItem {
  final String id;
  final String categoryId;
  final List<String> categoryNames;
  final List<String> categoryIds;
  final String name;
  final String? displayName;
  final String? shortCode;
  final String attribute; // 'VEG', 'NONVEG', 'EGG'
  final double price;
  final String? image;
  final List<MenuVariant> variants;
  final List<MenuAddon> addons;
  final bool customisable;
  /// From by-category-itemin `$lookup` on restaurant_favorite_menus.
  final bool isFavorite;
  /// Synthetic Extra Add-ons rail card (open-price line, no menu_id).
  final bool isExtraAddon;
  /// Leading "+ Custom" card on the Extra Add-ons rail.
  final bool isCustomAddonTrigger;

  bool get hasVariants => variants.isNotEmpty;
  bool get hasAddons => addons.isNotEmpty;
  bool get needsCustomisation =>
      !isExtraAddon &&
      !isCustomAddonTrigger &&
      (customisable || hasVariants || hasAddons);

  /// Visible title for POS tiles (never return blank — empty API strings happen).
  String get label {
    for (final raw in [displayName, name, shortCode]) {
      final t = raw?.trim() ?? '';
      if (t.isNotEmpty) return t;
    }
    return 'Item';
  }

  MenuItem({
    required this.id,
    required this.categoryId,
    this.categoryNames = const [],
    this.categoryIds = const [],
    required this.name,
    this.displayName,
    this.shortCode,
    required this.attribute,
    required this.price,
    this.image,
    this.variants = const [],
    this.addons = const [],
    this.customisable = false,
    this.isFavorite = false,
    this.isExtraAddon = false,
    this.isCustomAddonTrigger = false,
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
        if (group is! Map) continue;
        final groupMap = Map<String, dynamic>.from(group);
        // Skip empty $push slots from by-category-itemin aggregation.
        if (groupMap.isEmpty ||
            (groupMap['addon_id'] == null &&
                groupMap['_id'] == null &&
                groupMap['value'] == null)) {
          continue;
        }
        final addonId =
            groupMap['addon_id']?.toString() ??
            groupMap['_id']?.toString() ??
            '';
        final values = groupMap['value'];
        if (values is List) {
          for (var value in values) {
            if (value is Map && isActive(value['status'])) {
              addList.add(
                MenuAddon.fromJson({
                  ...Map<String, dynamic>.from(value),
                  'addon_id': addonId,
                  'name': groupMap['displayname'] ?? groupMap['name'],
                }),
              );
            }
          }
        } else if (groupMap['addonvalue_id'] != null ||
            groupMap['value_id'] != null) {
          addList.add(MenuAddon.fromJson(groupMap));
        }
      }
    }

    final customisable =
        json['customisable'] == 1 ||
        json['customisable'] == '1' ||
        json['customisable'] == true;

    final categoryNames = flattenCategoryNames(json['category']);
    final categoryIds = <String>{
      ...flattenCategoryIds(json['category']),
      if (json['category_id'] != null &&
          json['category_id'].toString().isNotEmpty)
        json['category_id'].toString(),
    };

    if (json['categories'] is List) {
      for (final c in (json['categories'] as List)) {
        if (c is Map) {
          final id =
              c['category_id']?.toString() ?? c['_id']?.toString() ?? '';
          if (id.isNotEmpty) categoryIds.add(id);
          final n =
              c['name']?.toString() ??
              c['valuename']?.toString() ??
              c['displayname']?.toString() ??
              '';
          if (n.trim().isNotEmpty) categoryNames.add(n.trim());
        }
      }
    }

    final isFavorite = json['is_favorite'] == true ||
        json['is_favorite'] == 1 ||
        json['is_favorite'] == '1';

    return MenuItem(
      id: json['_id']?.toString() ?? '',
      categoryId: json['category_id']?.toString() ??
          (categoryIds.isNotEmpty ? categoryIds.first : ''),
      categoryNames: categoryNames,
      categoryIds: categoryIds.toList(),
      name: _parseMenuName(json),
      displayName: json['displayname']?.toString(),
      shortCode:
          json['shortCode']?.toString() ?? json['short_code']?.toString(),
      attribute: (json['attribute']?.toString() ?? 'VEG').toUpperCase(),
      price: double.tryParse(json['price']?.toString() ?? '0') ?? 0.0,
      image: json['image']?.toString(),
      variants: varList,
      addons: addList,
      customisable: customisable,
      isFavorite: isFavorite,
      isExtraAddon: json['is_extra_addon'] == true ||
          json['is_extra_addon'] == 1 ||
          json['is_extra_addon'] == '1',
      isCustomAddonTrigger: json['is_custom_addon_trigger'] == true ||
          json['is_custom_addon_trigger'] == 1 ||
          json['_id']?.toString() == 'CUSTOM_ADDON_TRIGGER',
    );
  }
}
