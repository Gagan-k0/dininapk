import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';
import 'draft_cart_store.dart';

class AuthService {
  static const String _keyToken = 'auth_token';
  static const String _keyRestaurantId = 'restaurant_id';
  static const String _keyRestaurantName = 'restaurant_name';
  static const String _keyBaseUrl = 'api_base_url';
  static const String _keyDemoMode = 'demo_mode';

  /// Local-only test login (debug builds). Not a real API account.
  static const String demoUsername = 'admin@example.com';
  static const String demoPassword = 'mypassword';
  static const String demoToken = 'demo-token-local-only';
  static const String demoRestaurantId = 'demo-restaurant';
  static const String demoRestaurantName = 'Demo Restaurant (UI only)';

  Future<void> saveSession({
    required String token,
    required String restaurantId,
    String? restaurantName,
    String? baseUrl,
    bool demoMode = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyToken, token);
    await prefs.setString(_keyRestaurantId, restaurantId);
    await prefs.setBool(_keyDemoMode, demoMode);
    if (restaurantName != null) {
      await prefs.setString(_keyRestaurantName, restaurantName);
    }
    if (baseUrl != null && baseUrl.isNotEmpty) {
      await prefs.setString(_keyBaseUrl, baseUrl);
      ApiConfig.baseUrl = baseUrl;
    }
  }

  Future<bool> isDemoMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyDemoMode) ?? false;
  }

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyToken);
  }

  Future<String?> getRestaurantId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyRestaurantId);
  }

  Future<String?> getRestaurantName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyRestaurantName) ?? 'Fatfox Restaurant';
  }

  Future<void> initBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString(_keyBaseUrl);
    if (savedUrl != null && savedUrl.isNotEmpty) {
      ApiConfig.baseUrl = savedUrl;
    }
  }

  Future<bool> isLoggedIn() async {
    final token = await getToken();
    final restId = await getRestaurantId();
    return token != null && token.isNotEmpty && restId != null && restId.isNotEmpty;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken);
    await prefs.remove(_keyRestaurantId);
    await prefs.remove(_keyRestaurantName);
    await prefs.remove(_keyDemoMode);
    // Cart snapshots can hold guest names; unsent drafts are sales and stay.
    await DraftCartStore.clearSnapshots();
  }
}
