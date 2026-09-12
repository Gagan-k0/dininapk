import 'package:flutter/foundation.dart';

import '../config/api_config.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

class AuthProvider with ChangeNotifier {
  final AuthService _authService = AuthService();
  final ApiService _apiService = ApiService();

  bool _isLoggedIn = false;
  bool _isLoading = false;
  bool _isDemoMode = false;
  String? _token;
  String? _restaurantId;
  String _restaurantName = 'Fatfox Restaurant';
  String? _errorMessage;

  bool get isLoggedIn => _isLoggedIn;
  bool get isLoading => _isLoading;
  bool get isDemoMode => _isDemoMode;
  String? get token => _token;
  String? get restaurantId => _restaurantId;
  String get restaurantName => _restaurantName;
  String? get errorMessage => _errorMessage;

  Future<void> checkSession() async {
    await _authService.initBaseUrl();
    _isDemoMode = await _authService.isDemoMode();
    // Never restore a demo session — force real login after restart.
    if (_isDemoMode) {
      await _authService.logout();
      _isLoggedIn = false;
      _isDemoMode = false;
      _token = null;
      _restaurantId = null;
      notifyListeners();
      return;
    }
    _isLoggedIn = await _authService.isLoggedIn();
    if (_isLoggedIn) {
      _token = await _authService.getToken();
      _restaurantId = await _authService.getRestaurantId();
      _restaurantName = await _authService.getRestaurantName() ?? 'Fatfox Restaurant';
    }
    notifyListeners();
  }

  /// Debug / QA: enter the app without calling the API.
  /// Superadmin credentials do NOT work here — this is UI-only.
  Future<bool> enterDemoMode({String? baseUrl}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    final cleaned = (baseUrl ?? '').trim();
    if (cleaned.isNotEmpty) {
      ApiConfig.baseUrl = cleaned;
    }

    _token = AuthService.demoToken;
    _restaurantId = AuthService.demoRestaurantId;
    _restaurantName = AuthService.demoRestaurantName;
    await _authService.saveSession(
      token: _token!,
      restaurantId: _restaurantId!,
      restaurantName: _restaurantName,
      baseUrl: ApiConfig.cleanBaseUrl,
      demoMode: true,
    );
    _isDemoMode = true;
    _isLoggedIn = true;
    _isLoading = false;
    notifyListeners();
    return true;
  }

  Future<bool> login({
    required String email,
    required String password,
    required String baseUrl,
    String? restaurantNo,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // Demo is ONLY via "Skip login" button — never hijack real credentials.
      final cleaned = baseUrl.trim();
      if (cleaned.isNotEmpty) {
        ApiConfig.baseUrl = cleaned;
      }

      final res = await _apiService.login(
        email,
        password,
        restaurantNo: restaurantNo,
      );
      final data = res['data'] is Map
          ? res['data'] as Map<String, dynamic>
          : <String, dynamic>{};
      final user =
          data['user'] is Map ? data['user'] as Map<String, dynamic> : data;

      _token = data['access_token']?.toString() ??
          data['token']?.toString() ??
          res['token']?.toString() ??
          res['access_token']?.toString();
      // Prefer JWT restaurant_id — never fall back to user._id for staff
      // (staff _id is the staff document, not the restaurant).
      _restaurantId = user['restaurant_id']?.toString() ??
          data['restaurant_id']?.toString() ??
          res['restaurant_id']?.toString();
      // Restaurant-owner login sets restaurant_id == user._id
      if ((_restaurantId == null || _restaurantId!.isEmpty) &&
          user['usertype']?.toString() == 'admin' &&
          user['_id'] != null) {
        _restaurantId = user['_id'].toString();
      }
      _restaurantName = user['name']?.toString() ??
          user['username']?.toString() ??
          data['name']?.toString() ??
          'Fatfox Restaurant';

      if (_token != null &&
          _token!.isNotEmpty &&
          _restaurantId != null &&
          _restaurantId!.isNotEmpty) {
        await _authService.saveSession(
          token: _token!,
          restaurantId: _restaurantId!,
          restaurantName: _restaurantName,
          baseUrl: ApiConfig.cleanBaseUrl,
          demoMode: false,
        );
        _isDemoMode = false;
        _isLoggedIn = true;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage =
            'Login OK from server but missing token or restaurant_id. Use restaurant username (admin panel login), or staff login with Restaurant No. Superadmin cannot sign in here.';
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
    _isDemoMode = false;
    _token = null;
    _restaurantId = null;
    notifyListeners();
  }
}
