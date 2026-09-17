import 'package:shared_preferences/shared_preferences.dart';

/// Device-local POS chrome prefs (sidebar / cart collapse, etc.).
class PosUiPrefs {
  static const _railCollapsedKey = 'waiter_pos_category_rail_collapsed';
  static const _cartCollapsedKey = 'waiter_pos_cart_collapsed';

  static Future<bool> loadRailCollapsed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_railCollapsedKey) ?? false;
  }

  static Future<void> saveRailCollapsed(bool collapsed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_railCollapsedKey, collapsed);
  }

  static Future<bool> loadCartCollapsed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_cartCollapsedKey) ?? false;
  }

  static Future<void> saveCartCollapsed(bool collapsed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_cartCollapsedKey, collapsed);
  }
}
