import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/menu_model.dart';

/// Local snapshot of dine-in categories + menu (admin-style warm cache).
///
/// Used to paint the POS grid immediately while a network refresh runs.
class MenuCacheService {
  static const _catsPrefix = 'waiter_dinein_cats_v1_';
  static const _itemsPrefix = 'waiter_dinein_items_v1_';
  static const _savedAtPrefix = 'waiter_dinein_cache_at_v1_';

  Future<void> save({
    required String restaurantId,
    required List<Map<String, dynamic>> categories,
    required List<Map<String, dynamic>> items,
  }) async {
    if (restaurantId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_catsPrefix$restaurantId', jsonEncode(categories));
    await prefs.setString('$_itemsPrefix$restaurantId', jsonEncode(items));
    await prefs.setInt(
      '$_savedAtPrefix$restaurantId',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<CachedMenuSnapshot?> load(String restaurantId) async {
    if (restaurantId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final catsRaw = prefs.getString('$_catsPrefix$restaurantId');
    final itemsRaw = prefs.getString('$_itemsPrefix$restaurantId');
    if (catsRaw == null || itemsRaw == null) return null;

    try {
      final catsJson = jsonDecode(catsRaw);
      final itemsJson = jsonDecode(itemsRaw);
      if (catsJson is! List || itemsJson is! List) return null;

      final categories = <MenuCategory>[];
      for (final c in catsJson) {
        if (c is Map) {
          categories.add(MenuCategory.fromJson(Map<String, dynamic>.from(c)));
        }
      }
      final items = <MenuItem>[];
      for (final i in itemsJson) {
        if (i is Map) {
          items.add(MenuItem.fromJson(Map<String, dynamic>.from(i)));
        }
      }
      if (categories.isEmpty && items.isEmpty) return null;

      final atMs = prefs.getInt('$_savedAtPrefix$restaurantId');
      return CachedMenuSnapshot(
        categories: categories,
        items: items,
        savedAt: atMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(atMs),
      );
    } catch (_) {
      return null;
    }
  }
}

class CachedMenuSnapshot {
  const CachedMenuSnapshot({
    required this.categories,
    required this.items,
    this.savedAt,
  });

  final List<MenuCategory> categories;
  final List<MenuItem> items;
  final DateTime? savedAt;
}
