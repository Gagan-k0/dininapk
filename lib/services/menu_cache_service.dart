import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/menu_model.dart';

/// Local snapshot of everything the ordering screen needs that is NOT per-table:
/// categories, dine-in menu, tax rows, variant names, kitchen departments.
///
/// Opening a table used to cost 7 requests and re-downloaded the whole dine-in
/// menu every time. While this snapshot is fresh the POS paints from disk and
/// only the table + cart are fetched (2 requests), and offline it needs none.
class MenuCacheService {
  // v2: the snapshot gained tax/variant/department rows, so v1 payloads are
  // ignored rather than half-read.
  static const _catsPrefix = 'waiter_dinein_cats_v2_';
  static const _itemsPrefix = 'waiter_dinein_items_v2_';
  static const _extrasPrefix = 'waiter_dinein_extras_v2_';
  static const _savedAtPrefix = 'waiter_dinein_cache_at_v2_';

  /// A shift's worth of menu edits is rare; a waiter can force a refresh from
  /// Printer/POS "Sync menu" at any time.
  static const Duration defaultMaxAge = Duration(hours: 6);

  Future<void> save({
    required String restaurantId,
    required List<Map<String, dynamic>> categories,
    required List<Map<String, dynamic>> items,
    List<Map<String, dynamic>> taxRows = const [],
    List<Map<String, dynamic>> variants = const [],
    List<Map<String, dynamic>> departments = const [],
  }) async {
    if (restaurantId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    // Tax/variant/department fetches are best-effort: one 500 returns an empty
    // list. Overwriting good rows with that would then be served from cache for
    // hours (untaxed lines, one "General" KOT ticket), so keep the last good one.
    final previous = await load(restaurantId);
    List<Map<String, dynamic>> keep(
      List<Map<String, dynamic>> fresh,
      List<Map<String, dynamic>> old,
    ) =>
        fresh.isNotEmpty ? fresh : old;

    await prefs.setString('$_catsPrefix$restaurantId', jsonEncode(categories));
    await prefs.setString('$_itemsPrefix$restaurantId', jsonEncode(items));
    await prefs.setString(
      '$_extrasPrefix$restaurantId',
      jsonEncode({
        'tax': keep(taxRows, previous?.taxRows ?? const []),
        'variants': keep(variants, previous?.variants ?? const []),
        'departments': keep(departments, previous?.departments ?? const []),
      }),
    );
    // v1 held a full menu JSON per restaurant; nothing reads it now.
    await prefs.remove('waiter_dinein_cats_v1_$restaurantId');
    await prefs.remove('waiter_dinein_items_v1_$restaurantId');
    await prefs.remove('waiter_dinein_cache_at_v1_$restaurantId');
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
      final extrasRaw = prefs.getString('$_extrasPrefix$restaurantId');
      final extras = extrasRaw == null ? null : jsonDecode(extrasRaw);
      List<Map<String, dynamic>> rows(String key) {
        if (extras is! Map || extras[key] is! List) return const [];
        return (extras[key] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false);
      }

      return CachedMenuSnapshot(
        categories: categories,
        items: items,
        taxRows: rows('tax'),
        variants: rows('variants'),
        departments: rows('departments'),
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
    this.taxRows = const [],
    this.variants = const [],
    this.departments = const [],
    this.savedAt,
  });

  final List<MenuCategory> categories;
  final List<MenuItem> items;
  final List<Map<String, dynamic>> taxRows;
  final List<Map<String, dynamic>> variants;
  final List<Map<String, dynamic>> departments;
  final DateTime? savedAt;

  /// Young enough to open a table without re-fetching the catalog. A snapshot
  /// with no timestamp (pre-v2 or a failed write) is never treated as fresh.
  bool isFreshAt(DateTime now, {Duration maxAge = MenuCacheService.defaultMaxAge}) {
    final at = savedAt;
    if (at == null) return false;
    final age = now.difference(at);
    return !age.isNegative && age < maxAge;
  }

  bool get isFresh => isFreshAt(DateTime.now());

  /// Enough to paint the grid while a refresh runs.
  bool get hasCatalog => categories.isNotEmpty || items.isNotEmpty;

  /// Complete enough to REPLACE the opening catalog calls. A snapshot missing
  /// items or tax rows must not be served: an empty menu grid or untaxed cart
  /// lines would then persist until the snapshot aged out.
  bool get isSkippable =>
      categories.isNotEmpty && items.isNotEmpty && taxRows.isNotEmpty;
}
