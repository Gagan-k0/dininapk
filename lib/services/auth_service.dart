import 'package:shared_preferences/shared_preferences.dart';
import '../config/api_config.dart';

class AuthService {
  static const String _keyToken = 'auth_token';
  static const String _keyRestaurantId = 'restaurant_id';
  static const String _keyRestaurantName = 'restaurant_name';
  static const String _keyBaseUrl = 'api_base_url';

  Future<void> saveSession({
    required String token,
    required String restaurantId,
    String? restaurantName,
    String? baseUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyToken, token);
    await prefs.setString(_keyRestaurantId, restaurantId);
    if (restaurantName != null) {
      await prefs.setString(_keyRestaurantName, restaurantName);
    }
    if (baseUrl != null && baseUrl.isNotEmpty) {
      await prefs.setString(_keyBaseUrl, baseUrl);
      ApiConfig.baseUrl = baseUrl;
    }
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
  }
}
