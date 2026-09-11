import 'package:flutter/foundation.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

class AuthProvider with ChangeNotifier {
  final AuthService _authService = AuthService();
  final ApiService _apiService = ApiService();

  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _token;
  String? _restaurantId;
  String _restaurantName = 'Fatfox Restaurant';
  String? _errorMessage;

  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  String? get token => _token;
  String? get restaurantId => _restaurantId;
  String get restaurantName => _restaurantName;
  String? get errorMessage => _errorMessage;

  Future<void> checkSession() async {
    await _authService.initBaseUrl();
    _isLoggedIn = await _authService.isLoggedIn();
    if (_isLoggedIn) {
      _token = await _authService.getToken();
      _restaurantId = await _authService.getRestaurantId();
      _restaurantName = await _authService.getRestaurantName() ?? 'Fatfox Restaurant';
    }
    notifyListeners();
  }

  Future<bool> login({
    required String email,
    required String password,
    required String baseUrl,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final res = await _apiService.login(email, password);
      final data = res['data'] is Map ? res['data'] as Map<String, dynamic> : <String, dynamic>{};
      final user = data['user'] is Map ? data['user'] as Map<String, dynamic> : data;

      _token = data['access_token']?.toString() ?? data['token']?.toString() ?? res['token']?.toString() ?? res['access_token']?.toString();
      _restaurantId = user['restaurant_id']?.toString() ?? user['_id']?.toString() ?? data['restaurant_id']?.toString() ?? data['_id']?.toString() ?? res['restaurant_id']?.toString();
      _restaurantName = user['name']?.toString() ?? data['name']?.toString() ?? 'Fatfox Restaurant';

      if (_token != null && _token!.isNotEmpty && _restaurantId != null && _restaurantId!.isNotEmpty) {
        await _authService.saveSession(
          token: _token!,
          restaurantId: _restaurantId!,
          restaurantName: _restaurantName,
          baseUrl: baseUrl,
        );
        _isLoggedIn = true;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = 'Invalid response format: missing token or restaurant ID';
      }
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<void> logout() async {
    await _authService.logout();
    _isLoggedIn = false;
    _token = null;
    _restaurantId = null;
    notifyListeners();
  }
}
