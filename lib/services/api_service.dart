import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/table_model.dart';
import '../models/menu_model.dart';
import 'auth_service.dart';

class ApiService {
  final AuthService _authService = AuthService();

  Future<Map<String, dynamic>> login(
    String email,
    String password, {
    String? restaurantNo,
  }) async {
    final targetBase = ApiConfig.cleanBaseUrl;
    final no = restaurantNo?.trim() ?? '';
    debugPrint(
      '[Fatfox Login] Attempting login with baseUrl: $targetBase, '
      'user: $email, restaurantNo: ${no.isEmpty ? "(owner)" : no}',
    );

    // Match admin: Restaurant No. filled → staff-login ONLY.
    // Never try owner first when No. is set — dual-identity usernames (e.g. `test`
    // is owner of 10018 and staff of 10000) would otherwise ignore the No. and
    // land on the wrong empty restaurant.
    if (no.isNotEmpty) {
      return _staffLogin(
        email: email,
        password: password,
        restaurantNo: no,
        targetBase: targetBase,
      );
    }

    return _ownerLogin(
      email: email,
      password: password,
      targetBase: targetBase,
    );
  }

  Future<Map<String, dynamic>> _ownerLogin({
    required String email,
    required String password,
    required String targetBase,
  }) async {
    final restaurantPayload = jsonEncode({
      'username': email,
      'password': password,
    });
    try {
      final restUrl = Uri.parse('$targetBase${ApiConfig.restaurantLogin}');
      debugPrint('[Fatfox Login] Owner endpoint: $restUrl');
      final responseRest = await http
          .post(
            restUrl,
            headers: ApiConfig.headers(null, null),
            body: restaurantPayload,
          )
          .timeout(const Duration(seconds: 20));

      debugPrint(
        '[Fatfox Login] Owner status: ${responseRest.statusCode}, body: ${responseRest.body}',
      );
      if (responseRest.statusCode == 200) {
        final dataRest = jsonDecode(responseRest.body);
        if (_isSuccessResponse(dataRest)) {
          return dataRest as Map<String, dynamic>;
        }
        throw Exception(
          _extractErrorMessage(dataRest) ??
              'Invalid Credentials. For staff, enter Restaurant No.',
        );
      }
      throw Exception(
        'Login failed (HTTP ${responseRest.statusCode}). Check username/password.',
      );
    } catch (e) {
      debugPrint('[Fatfox Login] Owner login error: $e');
      throw Exception(
        _friendlyNetworkError(e, targetBase) ??
            e.toString().replaceAll('Exception: ', ''),
      );
    }
  }

  Future<Map<String, dynamic>> _staffLogin({
    required String email,
    required String password,
    required String restaurantNo,
    required String targetBase,
  }) async {
    try {
      final staffUrl = Uri.parse('$targetBase${ApiConfig.staffLogin}');
      final staffPayload = jsonEncode({
        'restaurant_no': restaurantNo,
        'username': email,
        'password': password,
      });
      debugPrint('[Fatfox Login] Staff endpoint: $staffUrl (no=$restaurantNo)');
      final responseStaff = await http
          .post(
            staffUrl,
            headers: ApiConfig.headers(null, null),
            body: staffPayload,
          )
          .timeout(const Duration(seconds: 20));
      debugPrint(
        '[Fatfox Login] Staff status: ${responseStaff.statusCode}, body: ${responseStaff.body}',
      );
      final dataStaff = jsonDecode(responseStaff.body);
      if (responseStaff.statusCode == 200 && _isSuccessResponse(dataStaff)) {
        return dataStaff as Map<String, dynamic>;
      }
      throw Exception(
        _extractErrorMessage(dataStaff) ??
            'Staff login failed. Check Restaurant No., username, and password.',
      );
    } catch (e) {
      debugPrint('[Fatfox Login] Staff login error: $e');
      throw Exception(
        _friendlyNetworkError(e, targetBase) ??
            e.toString().replaceAll('Exception: ', ''),
      );
    }
  }

  /// Clear message when tablet Wi‑Fi/DNS cannot resolve the API host.
  String? _friendlyNetworkError(Object e, String targetBase) {
    final s = e.toString();
    if (s.contains('Failed host lookup') ||
        s.contains('SocketException') ||
        s.contains('ClientException') ||
        s.contains('TimeoutException') ||
        s.contains('Network is unreachable')) {
      return 'No internet / DNS on this device.\n'
          'Cannot reach $targetBase\n'
          'Connect tablet to working Wi‑Fi, open that URL in Chrome on the tablet, '
          'then retry. Credentials are not the problem until the host resolves.';
    }
    return null;
  }

  bool _isSuccessResponse(dynamic data) {
    if (data is! Map) return false;
    // FatFox API: success is status.code == 200 (errors often still HTTP 200
    // with status.code 403/422/500). Never treat code 0/1 as success.
    final status = data['status'];
    if (status is Map) {
      final code = status['code'];
      if (code == 200) return true;
    }
    final resData = data['data'];
    if (resData is Map &&
        (resData['access_token'] != null || resData['token'] != null)) {
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
    if (status is Map &&
        status['message'] != null &&
        status['message'].toString().isNotEmpty) {
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

  String? _stringValue(dynamic value) {
    if (value == null) return null;
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  String? _extractCartId(Map<String, dynamic>? data) {
    if (data == null) return null;

    final directCartId =
        _stringValue(data['cart_id']) ?? _stringValue(data['cartId']);
    if (directCartId != null) return directCartId;

    final cartDetails = data['cart_details'] ?? data['cartDetails'];
    if (cartDetails is Map) {
      return _stringValue(cartDetails['_id']) ??
          _stringValue(cartDetails['cart_id']) ??
          _stringValue(cartDetails['cartId']);
    }

    final nestedTable = data['table'];
    if (nestedTable is Map<String, dynamic>) {
      return _extractCartId(nestedTable);
    }

    return null;
  }

  bool _isSuccessStatus(int statusCode, dynamic data) {
    return statusCode >= 200 && statusCode < 300 && _isSuccessResponse(data);
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
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final List list = _extractList(res['data']);
        return list
            .whereType<Map>()
            .map((e) => TableArea.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      debugPrint(
        '[Fatfox API] GetAreas HTTP ${response.statusCode}: ${response.body}',
      );
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
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final List list = _extractList(res['data']);
        final tables = <DineInTable>[];
        for (final e in list) {
          if (e is! Map) continue;
          try {
            tables.add(DineInTable.fromJson(Map<String, dynamic>.from(e)));
          } catch (err) {
            debugPrint('[Fatfox API] Skip bad table row: $err');
          }
        }
        return tables;
      }
      debugPrint(
        '[Fatfox API] GetTables HTTP ${response.statusCode}: ${response.body}',
      );
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
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.viewTable}/$tableId',
    );
    debugPrint('[Fatfox API] ViewTable: $url');

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        return res['data'] is Map<String, dynamic>
            ? res['data'] as Map<String, dynamic>
            : null;
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
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.getActiveCategories}$search',
    );
    debugPrint('[Fatfox API] Fetching Active Categories: $url');

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
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
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.getCategories}',
    );
    debugPrint('[Fatfox API] Fetching Categories: $url');

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
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
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
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
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.viewMenuById}/$menuId',
    );
    debugPrint('[Fatfox API] ViewMenu: $url');

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        // This endpoint returns data in status.message[0]
        if (res['status'] is Map && res['status']['message'] is List) {
          final list = res['status']['message'] as List;
          if (list.isNotEmpty) return list[0] as Map<String, dynamic>;
        }
        if (res['data'] is Map<String, dynamic>) {
          return res['data'] as Map<String, dynamic>;
        }
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
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
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
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.getTaxConfig}?area_id=&area_type=dinein',
    );
    debugPrint('[Fatfox API] Fetching Tax Config: $url');

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
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
  Future<List<Map<String, dynamic>>> getCartItemsByTableId(
    String tableId,
  ) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.getCartDetails}?tableId=$tableId',
    );
    debugPrint('[Fatfox API] Fetching Cart Items for table: $tableId');

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
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
      return {
        'status': {'code': 500, 'message': e.toString()},
      };
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
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.updateCartQty}',
    );

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

    debugPrint(
      '[Fatfox API] UpdateCartQty: cartId=$cartId, menuId=$cartmenuId, qty=$quantity',
    );

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] UpdateCartQty error: $e');
      return {
        'status': {'code': 500, 'message': e.toString()},
      };
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
      final response = await http.delete(
        url,
        headers: ApiConfig.headers(token, restId),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] DeleteCartMenu error: $e');
      return {
        'status': {'code': 500, 'message': e.toString()},
      };
    }
  }

  // ============================================================
  // KOT & Bill Operations
  // ============================================================

  /// Normalize waiter payment labels to admin POS enums (CASH / CARD / ONLINE).
  static String normalizePaymentType(String paymentType) {
    switch (paymentType.trim().toLowerCase()) {
      case 'cash':
        return 'CASH';
      case 'card':
        return 'CARD';
      case 'upi':
      case 'online':
        return 'ONLINE';
      default:
        final upper = paymentType.trim().toUpperCase();
        if (upper == 'CASH' || upper == 'CARD' || upper == 'ONLINE') {
          return upper;
        }
        return 'CASH';
    }
  }

  /// Set dine-in cart kitchen/print status.
  /// Mirrors admin: POST /restaurant/cart/setcartstatus
  Future<Map<String, dynamic>> setCartStatus({
    required String cartId,
    required String tableStatus,
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.setCartStatus}',
    );

    final body = {
      'cartId': cartId,
      'table_status': tableStatus,
    };

    debugPrint(
      '[Fatfox API] SetCartStatus: cart=$cartId status=$tableStatus',
    );

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] SetCartStatus error: $e');
      return {
        'status': {'code': 500, 'message': e.toString()},
      };
    }
  }

  /// Fire kitchen (PENDING→KOT / accept). Live path — not offline createorder.
  Future<Map<String, dynamic>> sendKotToKitchen({
    required String cartId,
  }) async {
    return setCartStatus(cartId: cartId, tableStatus: 'KOT');
  }

  /// Deprecated wrapper: live KOT uses setcartstatus, not createorder.
  @Deprecated('Use sendKotToKitchen / setCartStatus instead of createorder')
  Future<Map<String, dynamic>> createKotOrder({
    required String tableId,
    required String cartId,
  }) async {
    debugPrint(
      '[Fatfox API] createKotOrder deprecated → setCartStatus(KOT) '
      '(ignored tableId=$tableId)',
    );
    return sendKotToKitchen(cartId: cartId);
  }

  /// KOT print lines for a table.
  /// Mirrors admin: GET /restaurant/cart/viewmenu?tableId=&status=kot
  Future<List<Map<String, dynamic>>> getKotViewMenu({
    required String tableId,
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.kotPrintView}'
      '?tableId=$tableId&status=kot',
    );
    debugPrint('[Fatfox API] GetKotViewMenu: $url');

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        if (res is Map && _isSuccessResponse(res)) {
          return List<Map<String, dynamic>>.from(_extractList(res['data']));
        }
        // Some success payloads still put the list in data without status.code
        final list = _extractList(res is Map ? res['data'] : null);
        if (list.isNotEmpty) {
          return List<Map<String, dynamic>>.from(list);
        }
      }
    } catch (e) {
      debugPrint('[Fatfox API] GetKotViewMenu error: $e');
    }
    return [];
  }

  /// List discounts applicable to a dine-in order amount.
  /// GET /restaurant/discount/avaliable?orderType=dinein&orderAmount=&searchName=
  Future<List<Map<String, dynamic>>> listAvailableDiscounts({
    required double orderAmount,
    String searchName = '',
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.availableDiscounts}'
      '?orderType=dinein&orderAmount=$orderAmount&searchName=$searchName',
    );
    debugPrint('[Fatfox API] ListAvailableDiscounts: $url');

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(_extractList(res['data']));
      }
    } catch (e) {
      debugPrint('[Fatfox API] ListAvailableDiscounts error: $e');
    }
    return [];
  }

  /// Apply a discount to the cart.
  /// POST /restaurant/cart/setcartdiscount { cartId, discount_id }
  Future<Map<String, dynamic>> setCartDiscount({
    required String cartId,
    required String discountId,
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.setCartDiscount}',
    );
    final body = {'cartId': cartId, 'discount_id': discountId};

    debugPrint(
      '[Fatfox API] SetCartDiscount: cart=$cartId discount=$discountId',
    );

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] SetCartDiscount error: $e');
      return {
        'status': {'code': 500, 'message': e.toString()},
      };
    }
  }

  /// Remove discount from the cart.
  /// POST /restaurant/cart/removecartdiscount { cartId }
  Future<Map<String, dynamic>> removeCartDiscount({
    required String cartId,
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.removeCartDiscount}',
    );
    final body = {'cartId': cartId};

    debugPrint('[Fatfox API] RemoveCartDiscount: cart=$cartId');

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] RemoveCartDiscount error: $e');
      return {
        'status': {'code': 500, 'message': e.toString()},
      };
    }
  }

  /// Settle a dine-in bill.
  /// Mirrors web: POST /restaurant/cart/setcarttobill
  Future<Map<String, dynamic>> settleBill({
    required String cartId,
    String? tableId,
    String paymentType = 'CASH',
    Map<String, dynamic>? paymentFields,
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse('${ApiConfig.cleanBaseUrl}${ApiConfig.settleBill}');

    final normalized = normalizePaymentType(paymentType);
    final body = <String, dynamic>{
      'cartId': cartId,
      'cart_id': cartId,
      if (tableId != null && tableId.isNotEmpty) 'table_id': tableId,
      'paymentType': normalized,
      'payment_type': normalized,
      ...?paymentFields,
    };

    debugPrint('[Fatfox API] SettleBill: $url body: ${jsonEncode(body)}');

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] SettleBill error: $e');
      return {
        'status': {'code': 500, 'message': e.toString()},
      };
    }
  }

  /// Move an active cart to another table.
  /// Mirrors web: PATCH /restaurant/cart/switchtable/{cartId}
  Future<Map<String, dynamic>> switchTable({
    required String cartId,
    required String tableId,
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.switchTable}/$cartId',
    );

    final body = {'table_id': tableId};

    debugPrint('[Fatfox API] SwitchTable: cart=$cartId table=$tableId');

    try {
      final response = await http.patch(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body);
    } catch (e) {
      debugPrint('[Fatfox API] SwitchTable error: $e');
      return {
        'status': {'code': 500, 'message': e.toString()},
      };
    }
  }

  /// Accept or reject a QR dine-in order awaiting staff approval.
  /// Mirrors admin: POST /restaurant/cart/qr-approval { cartId, action }.
  Future<Map<String, dynamic>> decideQrOrder({
    required String cartId,
    required String action, // 'ACCEPT' | 'REJECT'
  }) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.qrApproval}',
    );

    final body = {'cartId': cartId, 'action': action};

    debugPrint('[Fatfox API] DecideQrOrder: cart=$cartId action=$action');

    try {
      final response = await http.post(
        url,
        headers: ApiConfig.headers(token, restId),
        body: jsonEncode(body),
      );
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[Fatfox API] DecideQrOrder error: $e');
      return {
        'status': {'code': 500, 'message': e.toString()},
      };
    }
  }

  // ============================================================
  // Printer Settings
  // ============================================================

  Future<Map<String, dynamic>> getPrinterSettings() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}${ApiConfig.getRestaurantView}',
    );

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
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
      body: jsonEncode({'table_id': tableId, 'cartmenu': menuItems}),
    );

    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> createKot({
    required String tableId,
    required String cartId,
  }) async {
    debugPrint(
      '[Fatfox API] createKot → sendKotToKitchen (ignored tableId=$tableId)',
    );
    return sendKotToKitchen(cartId: cartId);
  }

  Future<bool> releaseTable(String tableIdOrCartId) async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();

    try {
      var cartId = tableIdOrCartId;

      final tableDetails = await viewTableById(tableIdOrCartId);
      cartId = _extractCartId(tableDetails) ?? cartId;

      if (cartId == tableIdOrCartId) {
        final tables = await getTables();
        for (final table in tables) {
          if (table.id == tableIdOrCartId) {
            cartId = _extractCartId(table.cartDetails) ?? cartId;
            break;
          }
        }
      }

      final url = Uri.parse(
        '${ApiConfig.cleanBaseUrl}${ApiConfig.releaseTable}/$cartId',
      );
      debugPrint('[Fatfox API] ReleaseTable: $url');

      final response = await http.delete(
        url,
        headers: ApiConfig.headers(token, restId),
      );

      final data = jsonDecode(response.body);
      return _isSuccessStatus(response.statusCode, data);
    } catch (e) {
      debugPrint('[Fatfox API] ReleaseTable error: $e');
      return false;
    }
  }

  // ============================================================
  // Reservations & Live Orders
  // ============================================================

  Future<List<Map<String, dynamic>>> getReservations() async {
    final token = await _authService.getToken();
    final restId = await _authService.getRestaurantId();
    final url = Uri.parse(
      '${ApiConfig.cleanBaseUrl}/restaurant/reservation/all',
    );

    try {
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
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
      final response = await http.get(
        url,
        headers: ApiConfig.headers(token, restId),
      );
      if (response.statusCode == 200) {
        final res = jsonDecode(response.body);
        final raw = _extractList(res['data']);
        // Backend listallcarts is not tenant-scoped — filter client-side.
        const active = {
          'PENDING',
          'RUNNING',
          'KOT',
          'KOT_PRINT',
          'PRINTED',
        };
        final orders = <Map<String, dynamic>>[];
        for (final e in raw) {
          if (e is! Map) continue;
          final order = Map<String, dynamic>.from(e);
          final orderRest = order['restaurant_id']?.toString() ?? '';
          // Require tenant match when we know our restaurant (API is unscoped).
          if (restId != null && restId.isNotEmpty && orderRest != restId) {
            continue;
          }
          final status = order['table_status']?.toString().toUpperCase() ?? '';
          if (status.isNotEmpty && !active.contains(status)) continue;
          // Room-service carts are not dine-in floor orders.
          final service = order['service_type']?.toString() ?? '';
          if (service.toLowerCase().contains('room')) continue;
          orders.add(order);
        }
        debugPrint(
          '[Fatfox API] Live orders: ${orders.length} for restaurant '
          '(raw ${raw.length})',
        );
        return orders;
      }
      debugPrint(
        '[Fatfox API] GetLiveOrders HTTP ${response.statusCode}: ${response.body}',
      );
    } catch (e) {
      debugPrint('[Fatfox API] GetLiveOrders error: $e');
    }
    return [];
  }
}
