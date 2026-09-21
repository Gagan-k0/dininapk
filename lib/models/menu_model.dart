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

List<String> parseDepartments(dynamic raw) {
  if (raw == null) return const [];
  final out = <String>[];

  void addSingle(dynamic d) {
    if (d == null) return;
    if (d is Map) {
      final id = d['_id']?.toString() ??
          d['id']?.toString() ??
          d['name']?.toString() ??
          d['valuename']?.toString() ??
          d['department_name']?.toString() ??
          '';
      if (id.isNotEmpty && !out.contains(id)) out.add(id);
    } else if (d is List) {
      for (final item in d) {
        addSingle(item);
      }
    } else {
      final s = d.toString().trim();
      if (s.isNotEmpty && s != 'null') {
        if (s.contains(',')) {
          for (final part in s.split(',')) {
            final trimmed = part.trim();
            if (trimmed.isNotEmpty && trimmed != 'null' && !out.contains(trimmed)) {
              out.add(trimmed);
            }
          }
        } else if (!out.contains(s)) {
          out.add(s);
        }
      }
    }
  }

  addSingle(raw);
  return out;
}

class MenuCategory {
  final String id;
  final String categoryName;
  final String? valueName;
  final String? displayName;
  final String? image;
  final int count;
  final List<String> departments;

  MenuCategory({
    required this.id,
    required this.categoryName,
    this.valueName,
    this.displayName,
    this.image,
    this.count = 0,
    this.departments = const [],
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
      departments: parseDepartments(json['departments']),
    );
  }
}

class MenuVariant {
  final String id;
  final String name;
  final double price;

  MenuVariant({required this.id, required this.name, required this.price});

  factory MenuVariant.fromJson(Map<String, dynamic> json) {
    String extractName() {
      // 1. Direct string keys
      for (final key in [
        'valuename',
        'value_name',
        'name',
        'displayname',
        'displayName',
        'title',
        'variant_name',
        'variantName',
        'label',
        'value_title',
        'value_label',
        'value',
      ]) {
        final val = json[key];
        if (val is String &&
            val.trim().isNotEmpty &&
            val.trim().toLowerCase() != 'variant' &&
            val.trim().toLowerCase() != 'option') {
          return val.trim();
        }
      }

      // 2. Nested populated map keys (e.g. variant_id map, variant map, value map)
      for (final key in [
        'variant_id',
        'variant',
        'value',
        'variant_data',
        'variantData',
      ]) {
        final map = json[key];
        if (map is Map) {
          for (final subKey in [
            'valuename',
            'value_name',
            'name',
            'displayname',
            'displayName',
            'title',
            'variant_name',
            'label',
          ]) {
            final val = map[subKey];
            if (val is String &&
                val.trim().isNotEmpty &&
                val.trim().toLowerCase() != 'variant' &&
                val.trim().toLowerCase() != 'option') {
              return val.trim();
            }
          }
        }
      }

      return '';
    }

    // Prefer catalog variant_id (admin join key / createcart) over the
    // mongoose subdocument _id on menu.variants[] embeds.
    String extractId() {
      final variantId = json['variant_id'];
      if (variantId is String && variantId.trim().isNotEmpty) {
        return variantId.trim();
      }
      if (variantId is Map) {
        final nested = variantId['_id'] ?? variantId['id'];
        if (nested != null && nested.toString().trim().isNotEmpty) {
          return nested.toString().trim();
        }
      }
      return json['_id']?.toString() ??
          json['value_id']?.toString() ??
          json['id']?.toString() ??
          '';
    }

    final id = extractId();

    final price = double.tryParse(
          json['price']?.toString() ??
              json['variant_price']?.toString() ??
              json['addon_price']?.toString() ??
              '0',
        ) ??
        0.0;

    return MenuVariant(
      id: id,
      name: extractName(),
      price: price,
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
    final valueMap = json['value'] is Map<String, dynamic>
        ? json['value'] as Map<String, dynamic>
        : null;

    String extractOptionName() {
      for (final key in [
        'valuename',
        'value_name',
        'option_name',
        'optionName',
        'displayname',
        'displayName',
        'name',
        'title',
        'label',
      ]) {
        final val = json[key] ?? valueMap?[key];
        if (val is String && val.trim().isNotEmpty) {
          return val.trim();
        }
      }
      return '';
    }

    String extractGroupName() {
      for (final key in [
        'group_name',
        'groupName',
        'addon_group_name',
        'addon_name',
        'addonName',
        'name',
        'displayname',
        'title',
      ]) {
        final val = json[key];
        if (val is String && val.trim().isNotEmpty) {
          return val.trim();
        }
      }
      return '';
    }

    final price = double.tryParse(
          json['addon_price']?.toString() ??
              json['price']?.toString() ??
              json['amount']?.toString() ??
              json['addon_amount']?.toString() ??
              valueMap?['addon_price']?.toString() ??
              valueMap?['price']?.toString() ??
              '0',
        ) ??
        0.0;

    final optionName = extractOptionName();
    final groupName = extractGroupName();

    return MenuAddon(
      addonId: json['addon_id']?.toString() ??
          json['group_id']?.toString() ??
          json['_id']?.toString() ??
          '',
      id: json['addonvalue_id']?.toString() ??
          json['value_id']?.toString() ??
          json['option_id']?.toString() ??
          valueMap?['_id']?.toString() ??
          json['_id']?.toString() ??
          json['id']?.toString() ??
          '',
      name: groupName.isNotEmpty ? groupName : optionName,
      valueName: optionName.isNotEmpty ? optionName : groupName,
      price: price,
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
  /// Kitchen departments (KOT stations) inherited from category / denormalized.
  final List<String> departments;

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
    this.departments = const [],
  });

  factory MenuItem.fromJson(Map<String, dynamic> json) {
    bool isActive(dynamic status) =>
        status == null || status == 1 || status == '1';

    final varList = <MenuVariant>[];
    void parseVariantEntry(dynamic v) {
      if (v is Map) {
        final map = Map<String, dynamic>.from(v);
        if (isActive(map['status'])) {
          varList.add(MenuVariant.fromJson(map));
        }
      }
    }

    final rawVariants = json['variants'] ??
        json['variant'] ??
        json['variant_id'] ??
        json['variant_data'] ??
        json['variantData'];
    if (rawVariants is List) {
      for (var v in rawVariants) {
        parseVariantEntry(v);
      }
    } else if (rawVariants is Map) {
      parseVariantEntry(rawVariants);
    }

    final addList = <MenuAddon>[];
    void parseAddonEntries(dynamic list) {
      if (list is! List) return;
      for (var entry in list) {
        if (entry is! Map) continue;
        final groupMap = Map<String, dynamic>.from(entry);
        if (groupMap.isEmpty) continue;

        final values = groupMap['value'] ??
            groupMap['values'] ??
            groupMap['addon_values'] ??
            groupMap['addonValues'];
        final addonId = groupMap['addon_id']?.toString() ??
            groupMap['_id']?.toString() ??
            groupMap['id']?.toString() ??
            '';

        if (values is List) {
          for (var value in values) {
            if (value is Map && isActive(value['status'] ?? value['active'])) {
              final valMap = Map<String, dynamic>.from(value);
              final groupName = groupMap['displayname'] ??
                  groupMap['name'] ??
                  groupMap['title'] ??
                  groupMap['addon_name'] ??
                  groupMap['group_name'];
              final optionName = valMap['valuename'] ??
                  valMap['value_name'] ??
                  valMap['option_name'] ??
                  valMap['name'] ??
                  valMap['title'] ??
                  valMap['displayname'];
              addList.add(
                MenuAddon.fromJson({
                  ...valMap,
                  'addon_id': addonId,
                  'group_name': groupName,
                  'valuename': optionName,
                }),
              );
            }
          }
        } else if (groupMap['addonvalue_id'] != null ||
            groupMap['value_id'] != null ||
            groupMap['valuename'] != null ||
            groupMap['value_name'] != null) {
          // Do NOT treat bare {_id, addon_id} getmenu stubs as options —
          // those need catalog expand in enrichMenuItem (admin AllAvailableAddons).
          if (isActive(groupMap['status'] ?? groupMap['active'])) {
            addList.add(MenuAddon.fromJson(groupMap));
          }
        }
      }
    }

    for (final key in [
      'addons',
      'addOns',
      'addon',
      'addonData',
      'addon_data',
      'addon_ids',
      'addon_groups',
      'addonGroups',
      'customisation',
      'customisations',
      'customization',
      'customizations',
      'item_addons',
    ]) {
      parseAddonEntries(json[key]);
    }

    final customisable =
        json['customisable'] == 1 ||
        json['customisable'] == '1' ||
        json['customisable'] == true ||
        json['customizable'] == 1 ||
        json['customizable'] == '1' ||
        json['customizable'] == true ||
        json['is_customisable'] == 1 ||
        json['is_customisable'] == '1' ||
        json['is_customisable'] == true ||
        json['is_customizable'] == 1 ||
        json['is_customizable'] == '1' ||
        json['is_customizable'] == true ||
        json['is_customisation'] == 1 ||
        json['is_customisation'] == '1' ||
        json['is_customisation'] == true ||
        json['is_customization'] == 1 ||
        json['is_customization'] == '1' ||
        json['is_customization'] == true ||
        json['isCustomisation'] == 1 ||
        json['isCustomisation'] == '1' ||
        json['isCustomisation'] == true ||
        json['isCustomization'] == 1 ||
        json['isCustomization'] == '1' ||
        json['isCustomization'] == true ||
        json['is_custom'] == 1 ||
        json['is_custom'] == '1' ||
        json['is_custom'] == true ||
        json['has_addons'] == 1 ||
        json['has_addons'] == '1' ||
        json['has_addons'] == true ||
        json['has_addon'] == 1 ||
        json['has_addon'] == '1' ||
        json['has_addon'] == true ||
        json['has_variants'] == 1 ||
        json['has_variants'] == '1' ||
        json['has_variants'] == true;

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
      departments: parseDepartments(json['departments'] ?? json['department_ids']),
    );
  }
}
