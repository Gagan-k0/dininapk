import '../models/menu_model.dart';

/// Sentinel rail ids (not real category ObjectIds).
const kFavoritesCategoryId = '__favorites__';
const kExtraAddonsCategoryId = '__extra_addons__';
const kCustomAddonTriggerId = 'CUSTOM_ADDON_TRIGGER';

bool isSpecialMenuMode(String? categoryId) =>
    categoryId == kFavoritesCategoryId || categoryId == kExtraAddonsCategoryId;

/// Port of admin `mapExtraAddonsToCards` — flatten addon groups into POS tiles
/// plus a leading "+ Custom" trigger.
List<MenuItem> mapExtraAddonCards(
  List<Map<String, dynamic>> addonGroups, {
  String search = '',
}) {
  final seen = <String>{};
  final options = <MenuItem>[];
  final term = search.trim().toLowerCase();

  for (final addon in addonGroups) {
    final values = addon['value'];
    if (values is! List) continue;
    for (final raw in values) {
      if (raw is! Map) continue;
      final v = Map<String, dynamic>.from(raw);
      final status = v['status'];
      if (status != 1 && status != '1') continue;

      final name =
          (v['valuename'] ?? v['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final price = double.tryParse(v['price']?.toString() ?? '0') ?? 0;
      final shortCode = v['shortCode']?.toString() ?? '';
      final key = '${name}__$price';
      if (seen.contains(key)) continue;

      if (term.isNotEmpty &&
          !name.toLowerCase().contains(term) &&
          !shortCode.toLowerCase().contains(term)) {
        continue;
      }

      seen.add(key);
      options.add(
        MenuItem(
          id: v['_id']?.toString().isNotEmpty == true
              ? v['_id'].toString()
              : key,
          categoryId: kExtraAddonsCategoryId,
          name: name,
          displayName: name,
          shortCode: shortCode.isEmpty ? null : shortCode,
          attribute: (v['attribute']?.toString() ?? 'VEG').toUpperCase(),
          price: price,
          isExtraAddon: true,
        ),
      );
    }
  }

  options.sort(
    (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
  );

  return [
    MenuItem(
      id: kCustomAddonTriggerId,
      categoryId: kExtraAddonsCategoryId,
      name: '+ Custom',
      displayName: '+ Custom',
      attribute: 'VEG',
      price: 0,
      isCustomAddonTrigger: true,
    ),
    ...options,
  ];
}
