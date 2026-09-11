import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/table_model.dart';
import '../models/menu_model.dart';
import 'auth_service.dart';

class ApiService {
  final AuthService _authService = AuthService();

  Future<Map<String, dynamic>> login(String email, String password) async {
    final payload = jsonEncode({
      'username': email,
      'email': email,
      'password': password,
    });

    final targetBase = ApiConfig.cleanBaseUrl;
    debugPrint('[Fatfox Login] Attempting login with baseUrl: $targetBase, user: $email');

    // 1. Try Restaurant Login endpoint first (with 5s timeout)
    try {
      final restUrl = Uri.parse('$targetBase${ApiConfig.restaurantLogin}');
      debugPrint('[Fatfox Login] Calling endpoint: $restUrl');
      final responseRest = await http
          .post(restUrl, headers: ApiConfig.headers(null, null), body: payload)
          .timeout(const Duration(seconds: 5));

      debugPrint('[Fatfox Login] Response status: ${responseRest.statusCode}, body: ${responseRest.body}');
      if (responseRest.statusCode == 200) {
        final dataRest = jsonDecode(responseRest.body);
        if (_isSuccessResponse(dataRest)) {
          return dataRest;
        }
        final errMsg = _extractErrorMessage(dataRest);
        if (errMsg != null) {
          throw Exception(errMsg);
        }
      }
    } catch (e) {
      debugPrint('[Fatfox Login] Restaurant login error: $e');
      if (e.toString().contains('Invalid Credentials') || e.toString().contains('User Blocked')) {
        rethrow;
      }
    }

    // 2. Try Admin Login endpoint as fallback
    try {
      final adminUrl = Uri.parse('$targetBase/admin/login');
      debugPrint('[Fatfox Login] Fallback calling admin endpoint: $adminUrl');
      final responseAdmin = await http
          .post(adminUrl, headers: ApiConfig.headers(null, null), body: payload)
          .timeout(const Duration(seconds: 5));

      debugPrint('[Fatfox Login] Admin response status: ${responseAdmin.statusCode}, body: ${responseAdmin.body}');
      if (responseAdmin.statusCode == 200) {
        final dataAdmin = jsonDecode(responseAdmin.body);
        if (_isSuccessResponse(dataAdmin)) {
          return dataAdmin;
        }
      }
    } catch (e) {
      debugPrint('[Fatfox Login] Admin login error: $e');
    }

    // 3. Try User Login endpoint as final fallback
    try {
      final userUrl = Uri.parse('$targetBase${ApiConfig.login}');
      debugPrint('[Fatfox Login] Fallback calling user endpoint: $userUrl');
      final responseUser = await http
          .post(userUrl, headers: ApiConfig.headers(null, null), body: payload)
          .timeout(const Duration(seconds: 5));

      debugPrint('[Fatfox Login] User response status: ${responseUser.statusCode}, body: ${responseUser.body}');
      final dataUser = jsonDecode(responseUser.body);
      if (responseUser.statusCode == 200 && _isSuccessResponse(dataUser)) {
        return dataUser;
      }
      final errMsg = _extractErrorMessage(dataUser);
      throw Exception(errMsg ?? 'Login failed. Please check your staff username & password.');
    } catch (e) {
      debugPrint('[Fatfox Login] Final login error: $e');
      throw Exception(e.toString().replaceAll('Exception: ', ''));
    }
  }

  bool _isSuccessResponse(dynamic data) {
    if (data is! Map) return false;
    final status = data['status'];
    if (status == 1 || status == true) return true;
    if (status is Map) {
      final code = status['code'];
      if (code == 200 || code == 1 || code == 0) return true;
    }
    // Check if token exists directly inside data object
    final resData = data['data'];
    if (resData is Map && (resData['access_token'] != null || resData['token'] != null)) {
      return true;
    }
    return false;
  }

  String? _extractErrorMessage(dynamic data) {
    if (data is! Map) return null;
    if (data['message'] != null && data['message'].toString().isNotEmpty) {
      return data['message'].toString();
    }
    final status = data['status'];
    if (status is Map && status['message'] != null && status['message'].toString().isNotEmpty) {
      return status['message'].toString();
    }
    if (status is String && status.isNotEmpty) {
      return status;
    }
    return null;
  }

  List _extractList(dynamic data) {
    if (data is List) return data;
    if (data is Map && data['docs'] is List) return data['docs'] as List;
    return [];
  }

  // ============================================================
  // Table Management
  // ============================================================

  Future<List<TableArea>> getAreas() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.getAreaList}');
    debugPrint('[Fatfox API] Fetching Areas: $url');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final List list = _extractList(res['data']);
        return list.map((e) => TableArea.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetAreas error: $e');
    }
    return [];
  }

  Future<List<DineInTable>> getTables() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.getAllTables}');
    debugPrint('[Fatfox API] Fetching Tables: $url');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final List list = _extractList(res['data']);
        return list.map((e) => DineInTable.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetTables error: $e');
    }
    return [];
  }

  /// Fetch a single table's details by its ID.
  /// Mirrors web: GET /restaurant/table/view/{tableId}
  Future<Map<String, dynamic>?> viewTableById(String tableId) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.viewTable}/$tableId');
    debugPrint('[Fatfox API] ViewTable: $url');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        return res['data'] is Map<String, dynamic> ? res['data'] as Map<String, dynamic> : null;
      }
    } catch (e) {
      debugPrint('[Fatfox API] ViewTable error: $e');
    }
    return null;
  }

  // ============================================================
  // Categories (active categories for POS)
  // ============================================================

  /// Fetch all active food categories.
  /// Mirrors web: GET /restaurant/category/active-all?searchName=
  Future<List<MenuCategory>> getActiveCategories({String search = ''}) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.getActiveCategories}$search');
    debugPrint('[Fatfox API] Fetching Active Categories: $url');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final List list = _extractList(res['data']);
        return list.map((e) => MenuCategory.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetActiveCategories error: $e');
    }
    return [];
  }

  // Legacy getCategories kept for backward compat
  Future<List<MenuCategory>> getCategories() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.getCategories}');
    debugPrint('[Fatfox API] Fetching Categories: $url');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final List list = _extractList(res['data']);
        return list.map((e) => MenuCategory.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetCategories error: $e');
    }
    return [];
  }

  // ============================================================
  // Menu Items
  // ============================================================

  /// Fetch dinein menu items, optionally filtered by category.
  /// Mirrors web: GET /restaurant/menu/by-category-itemin?categoryId=&searchItemIn=dinein&searchName=
  Future<List<MenuItem>> getMenuItemsByCategory({
    String categoryId = '',
    String search = '',
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.getMenuByCategory}'
      '?categoryId=$categoryId&searchItemIn=dinein&searchName=$search',
    );
    debugPrint('[Fatfox API] Fetching Menu By Category: $url');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final List list = _extractList(res['data']);
        return list.map((e) => MenuItem.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetMenuByCategory error: $e');
    }
    return [];
  }

  /// Fetch a single menu item by ID (for variant/addon details).
  /// Mirrors web: GET /restaurant/menu/getmenu/{menuId}
  Future<Map<String, dynamic>?> getMenuById(String menuId) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.viewMenuById}/$menuId');
    debugPrint('[Fatfox API] ViewMenu: $url');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        // This endpoint returns data in status.message[0]
        if (res['status'] is Map && res['status']['message'] is List) {
          final list = res['status']['message'] as List;
          if (list.isNotEmpty) return list[0] as Map<String, dynamic>;
        }
        if (res['data'] is Map<String, dynamic>) return res['data'] as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetMenuById error: $e');
    }
    return null;
  }

  // Legacy getMenuItems kept for backward compat
  Future<List<MenuItem>> getMenuItems() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.getAllMenu}');
    debugPrint('[Fatfox API] Fetching Menu Items: $url');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final List list = _extractList(res['data']);
        return list.map((e) => MenuItem.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetMenuItems error: $e');
    }
    return [];
  }

  // ============================================================
  // Tax Configuration
  // ============================================================

  /// Fetch dinein tax config.
  /// Mirrors web: GET /restaurant/tax/settax?area_id=&area_type=dinein
  Future<List<Map<String, dynamic>>> getTaxConfig() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.getTaxConfig}?area_id=&area_type=dinein');
    debugPrint('[Fatfox API] Fetching Tax Config: $url');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        if (res['data'] is List) {
          return List<Map<String, dynamic>>.from(res['data']);
        }
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetTaxConfig error: $e');
    }
    return [];
  }

  // ============================================================
  // Cart Operations (matching web panel's UserService)
  // ============================================================

  /// Fetch cart items for a table.
  /// Mirrors web: GET /restaurant/cart/listallcartmenus?tableId=
  Future<List<Map<String, dynamic>>> getCartItemsByTableId(String tableId) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.getCartDetails}?tableId=$tableId');
    debugPrint('[Fatfox API] Fetching Cart Items for table: $tableId');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        if (res['data'] is List) {
          return List<Map<String, dynamic>>.from(res['data']);
        }
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetCartItems error: $e');
    }
    return [];
  }

  /// Add an item to the cart (create cart or add to existing).
  /// Mirrors web: POST /restaurant/cart/createcart
  Future<Map<String, dynamic>> createCartItem({
    required String tableId,
    required String? menuId,
    required double menuPrice,
    String? variantId,
    List<Map<String, dynamic>>? addons,
    String? taxId,
    String? taxName,
    String? taxValueType,
    String? taxValueAmount,
    String? discountId,
    String? discountName,
    String? discountValueType,
    String? discountSetAt,
    String? discountValueAmount,
    String? maxDiscount,
    String containerPrice = '0',
    bool isExtraAddon = false,
    String? menuName,
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.addToCart}');

    final body = {
      'table_id': tableId,
      'table_status': 'BLANK',
      'menu_id': menuId,
      'menu_price': menuPrice,
      'variant_id': variantId,
      'addons': addons ?? [],
      'payment_status': '0',
      'tax_id': taxId,
      'tax_name': taxName,
      'tax_value_type': taxValueType,
      'tax_value_amount': taxValueAmount,
      'discount_id': discountId,
      'discount_name': discountName,
      'discount_value_type': discountValueType,
      'discount_set_at': discountSetAt,
      'discount_value_amount': discountValueAmount,
      'max_discount': maxDiscount,
      'container_price': containerPrice,
      'is_extra_addon': isExtraAddon,
      'menu_name': menuName,
    };

    debugPrint('[Fatfox API] CreateCart: $url body: ${jsonEncode(body)}');

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] CreateCart error: $e');
      return {'status': {'code': 500, 'message': e.toString()}};
    }
  }

  /// Update cart item quantity.
  /// Mirrors web: POST /restaurant/cart/updatecartmenuquantity
  Future<Map<String, dynamic>> updateCartItemQuantity({
    required String cartId,
    required String cartmenuId,
    required int quantity,
    String? taxId,
    String? taxValueType,
    String? taxValueAmount,
    String? discountId,
    String? discountValueType,
    String? discountSetAt,
    String? discountValueAmount,
    String? maxDiscount,
    String containerPrice = '0',
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.updateCartQty}');

    final body = {
      'cartId': cartId,
      'cartmenuId': cartmenuId,
      'quantity': quantity,
      'tax_id': taxId,
      'tax_value_type': taxValueType,
      'tax_value_amount': taxValueAmount,
      'discount_id': discountId,
      'discount_value_type': discountValueType,
      'discount_set_at': discountSetAt,
      'discount_value_amount': discountValueAmount,
      'max_discount': maxDiscount,
      'container_price': containerPrice,
    };

    debugPrint('[Fatfox API] UpdateCartQty: cartId=$cartId, menuId=$cartmenuId, qty=$quantity');

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] UpdateCartQty error: $e');
      return {'status': {'code': 500, 'message': e.toString()}};
    }
  }

  /// Delete a cart menu item.
  /// Mirrors web: DELETE /restaurant/cart/deletemenu?cartId=&cartmenuId=&...
  Future<Map<String, dynamic>> deleteCartMenuItem({
    required String cartId,
    required String cartmenuId,
    String? taxId,
    String? taxValueType,
    String? taxValueAmount,
    String? discountId,
    String? discountValueType,
    String? discountSetAt,
    String? discountValueAmount,
    String? maxDiscount,
    String containerPrice = '0',
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.deleteCartMenu}'
      '?cartId=$cartId&cartmenuId=$cartmenuId'
      '&tax_id=$taxId&tax_value_type=$taxValueType&tax_value_amount=$taxValueAmount'
      '&discount_id=$discountId&discount_value_type=$discountValueType'
      '&discount_set_at=$discountSetAt&discount_value_amount=$discountValueAmount'
      '&max_discount=$maxDiscount&container_price=$containerPrice',
    );

    debugPrint('[Fatfox API] DeleteCartMenu: $url');

    try {
      final response = await http.delete(url, headers: ApiConfig.headers(token, restId));
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] DeleteCartMenu error: $e');
      return {'status': {'code': 500, 'message': e.toString()}};
    }
  }

  // ============================================================
  // KOT & Bill Operations
  // ============================================================

  /// Create a KOT order.
  /// Mirrors web: POST /restaurant/cart/createorder
  Future<Map<String, dynamic>> createKotOrder({
    required String tableId,
    required String cartId,
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.createKot}');

    final body = {
      'table_id': tableId,
      'cart_id': cartId,
    };

    debugPrint('[Fatfox API] CreateKOT: table=$tableId cart=$cartId');

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] CreateKOT error: $e');
      return {'status': {'code': 500, 'message': e.toString()}};
    }
  }

  // ============================================================
  // Printer Settings
  // ============================================================

  Future<Map<String, dynamic>> getPrinterSettings() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.getRestaurantView}');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final data = res['data'] ?? {};
        return data['printer_settings'] as Map<String, dynamic>? ?? {};
      }
    } catch (_) {}
    return {};
  }

  // Legacy addToCart kept for backward compat
  Future<Map<String, dynamic>> addToCart({
    required String tableId,
    required List<Map<String, dynamic>> menuItems,
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.addToCart}');

    final response = await http.post(
      url,
      headers: ApiConfig.headers(token, restId),
      body: jsonEncode({
        'table_id': tableId,
        'cartmenu': menuItems,
      }),
    );

    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> createKot({
    required String tableId,
    required String cartId,
  }) async {
    return createKotOrder(tableId: tableId, cartId: cartId);
  }

  Future<bool> releaseTable(String tableId) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.releaseTable}');

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode({'table_id': tableId}),
      );

      final data = jsonDecode(response.body);
      return response.statusCode == 200 && (data['status'] == 1 || data['status'] == true);
    } catch (_) {
      return true; // Optimistic release fallback
    }
  }

  // ============================================================
  // Reservations & Live Orders
  // ============================================================

  Future<List<Map<String, dynamic>>> getReservations() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}/restaurant/reservation/all');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(_extractList(res['data']));
      }
    } catch (_) {}
    return [];
  }

  Future<List<Map<String, dynamic>>> getLiveOrders() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.getLiveCarts}');

    try {
      final response = await http.get(url, headers: ApiConfig.headers(token, restId));
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(_extractList(res['data']));
      }
    } catch (_) {}
    return [];
  }
}
