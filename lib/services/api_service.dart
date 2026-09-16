import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/table_model.dart';
import '../models/menu_model.dart';
import 'api_client.dart';
import 'auth_service.dart';

export 'api_client.dart' show ApiException, ApiEnvelope, friendlyError;

/// All backend calls for the waiter app. Every method except [login] goes
/// through [ApiClient], so a refusal or expired session THROWS [ApiException]
/// instead of quietly returning an empty list.
class ApiService {
  final AuthService _authService;
  final ApiClient _client;

  ApiService({AuthService? auth, ApiClient? client})
      : _authService = auth ?? AuthService(),
        _client = client ?? ApiClient(auth: auth);

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
        '[Fatfox Login] Owner status: ${responseRest.statusCode}',
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
        '[Fatfox Login] Staff status: ${responseStaff.statusCode}',
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


  // ============================================================
  // Floor: areas + tables
  // ============================================================

  /// GET /restaurant/table/area/all-avaliable?searchName=
  /// Throws [ApiException] on refusal (a wrong/expired JWT must never look
  /// like an empty floor).
  Future<List<TableArea>> getAreas() async {
    final env = await _client.get(ApiConfig.getAreaList);
    return env.mapList.map(TableArea.fromJson).toList();
  }

  /// GET /restaurant/table/all?searchNumber=
  Future<List<DineInTable>> getTables() async {
    final env = await _client.get(ApiConfig.getAllTables);
    return env.mapList.map(DineInTable.fromJson).toList();
  }

  /// GET /restaurant/table/view/{tableId} → `{table_id, area_id, cart_id, table_number, …}`
  Future<Map<String, dynamic>?> viewTableById(String tableId) async {
    final env = await _client.get('${ApiConfig.viewTable}/$tableId');
    if (env.map != null) return env.map;
    final list = env.mapList;
    return list.isNotEmpty ? list.first : null;
  }

  // ============================================================
  // Menu
  // ============================================================

  /// GET /restaurant/category/active-all?searchName=
  Future<List<MenuCategory>> getActiveCategories({String search = ''}) async {
    final maps = await getActiveCategoryMaps(search: search);
    return maps.map(MenuCategory.fromJson).toList();
  }

  /// Raw category maps (for local menu cache).
  Future<List<Map<String, dynamic>>> getActiveCategoryMaps({
    String search = '',
  }) async {
    final env = await _client.get(
      ApiConfig.getActiveCategoriesPath,
      query: {'searchName': search},
    );
    return env.mapList;
  }

  /// GET /restaurant/menu/by-category-itemin?categoryId=&searchItemIn=dinein&searchName=
  Future<List<MenuItem>> getMenuItemsByCategory({
    String categoryId = '',
    String search = '',
  }) async {
    final maps = await getDineinMenuMaps(
      categoryId: categoryId,
      search: search,
    );
    return maps.map(MenuItem.fromJson).toList();
  }

  /// Raw dine-in menu maps (for local menu cache).
  Future<List<Map<String, dynamic>>> getDineinMenuMaps({
    String categoryId = '',
    String search = '',
  }) async {
    final env = await _client.get(
      ApiConfig.getMenuByCategory,
      query: {
        'categoryId': categoryId,
        'searchItemIn': 'dinein',
        'searchName': search,
      },
    );
    return env.mapList;
  }

  /// GET /restaurant/add-on/all-avaliable?searchName= — Extra Add-ons rail.
  Future<List<Map<String, dynamic>>> getAllAvailableAddons({
    String search = '',
  }) async {
    final env = await _client.get(
      ApiConfig.allAvailableAddons,
      query: {'searchName': search},
    );
    return env.mapList;
  }

  /// GET /restaurant/variant/all?searchName= — catalog for joining variant names.
  Future<List<Map<String, dynamic>>> getAllVariants({
    String search = '',
  }) async {
    final env = await _client.get(
      ApiConfig.allVariants,
      query: {'searchName': search},
    );
    return env.mapList;
  }

  /// GET /restaurant/kitchen-department?all=true — kitchen stations for KOT routing.
  Future<List<Map<String, dynamic>>> getKitchenDepartments({
    bool activeOnly = false,
  }) async {
    final env = await _client.get(
      ApiConfig.kitchenDepartments,
      query: {
        'all': 'true',
        if (activeOnly) 'activeOnly': 'true',
      },
    );
    return env.mapList;
  }

  /// GET /restaurant/menu/getmenu/{menuId} — variant/addon details.
  Future<Map<String, dynamic>?> getMenuById(String menuId) async {
    try {
      final env = await _client.get('${ApiConfig.viewMenuById}/$menuId');
      // This endpoint historically put the doc in status.message[0].
      final status = env.raw['status'];
      if (status is Map && status['message'] is List) {
        final list = status['message'] as List;
        if (list.isNotEmpty && list.first is Map) {
          return Map<String, dynamic>.from(list.first as Map);
        }
      }
      return env.map;
    } on ApiException catch (e) {
      if (e.isAuth) rethrow;
      debugPrint('[Fatfox API] GetMenuById error: $e');
      return null;
    }
  }

  /// GET /restaurant/tax/settax?area_id=&area_type=dinein
  /// Rows: `{_id, tax_type, name, value_type, value_amount}`.
  Future<List<Map<String, dynamic>>> getTaxConfig() async {
    final env = await _client.get(
      ApiConfig.getTaxConfig,
      query: {'area_id': '', 'area_type': 'dinein'},
    );
    return env.mapList;
  }

  /// GET /restaurant/settings/view — the SAME endpoint the admin exe/website
  /// read. Returns the whole restaurant doc, including `printer_settings`
  /// (`{receipt_settings, printer_config}`), shared across every device.
  Future<Map<String, dynamic>> getRestaurantSettingsView() async {
    final env = await _client.get(ApiConfig.restaurantSettingsView);
    return env.map ?? {};
  }

  /// GET /restaurant/settings/printer-settings → `{ printer_settings }`.
  Future<Map<String, dynamic>> getPrinterSettings() async {
    final env = await _client.get(ApiConfig.printerSettings);
    return env.map ?? {};
  }

  /// PUT /restaurant/settings/update-printer-settings — the SAME endpoint the
  /// admin exe/website write to, so a change made here is visible there too.
  Future<void> updatePrinterSettings({
    Map<String, dynamic>? receiptSettings,
    Map<String, dynamic>? printerConfig,
  }) async {
    await _client.put(
      ApiConfig.updatePrinterSettings,
      body: {
        if (receiptSettings != null) 'receipt_settings': receiptSettings,
        if (printerConfig != null) 'printer_config': printerConfig,
      },
    );
  }

  // ============================================================
  // Cart (live, matches admin dinein-food-categories)
  // ============================================================

  /// GET /restaurant/cart/listallcartmenus?tableId=
  /// Returns the cart snapshot list (usually 0 or 1 cart) with `cartMenuData`.
  Future<List<Map<String, dynamic>>> getCartItemsByTableId(String tableId) async {
    final env = await _client.get(
      ApiConfig.getCartDetails,
      query: {'tableId': tableId},
    );
    return env.mapList;
  }

  /// GET /restaurant/cart/vieworder-save?tableId= — cart header joined with the
  /// restaurant doc (name/address/gstin/UPI). Used for the printed bill header.
  Future<Map<String, dynamic>?> getBillView(String tableId) async {
    final env = await _client.get(
      ApiConfig.billView,
      query: {'tableId': tableId},
    );
    if (env.map != null) return env.map;
    final list = env.mapList;
    return list.isNotEmpty ? list.first : null;
  }

  /// GET /restaurant/cart/viewmenu?tableId=&status=kot|all|reprint
  /// `kot` = un-printed lines (kotprint_status 0), `all` = KOT'd lines,
  /// `reprint` = KOT'd incl. cancelled. A table with no cart answers with no
  /// `data` key at all — that is an empty list, not an error.
  Future<List<Map<String, dynamic>>> getViewMenu({
    required String tableId,
    String status = 'kot',
  }) async {
    final env = await _client.get(
      ApiConfig.kotPrintView,
      query: {'tableId': tableId, 'status': status},
    );
    return env.mapList;
  }

  /// Back-compat alias for the KOT ticket lines.
  Future<List<Map<String, dynamic>>> getKotViewMenu({required String tableId}) =>
      getViewMenu(tableId: tableId, status: 'kot');

  /// POST /restaurant/cart/createcart — add one line (or bump a matching one).
  /// Server re-derives the price for real menu items; `menuPrice` is only
  /// authoritative for `isExtraAddon` lines. `containerPrice` MUST echo the
  /// cart's current value or the server resets it to 0.
  Future<ApiEnvelope> createCartItem({
    required String tableId,
    String? cartId,
    required String? menuId,
    required double menuPrice,
    String? variantId,
    List<Map<String, dynamic>>? addons,
    String? taxId,
    String? taxName,
    String? taxValueType,
    String? taxValueAmount,
    String containerPrice = '0',
    bool isExtraAddon = false,
    String? menuName,
    int quantity = 1,
    String? description,
  }) {
    return _client.post(ApiConfig.addToCart, body: {
      'table_id': tableId,
      if (cartId != null && cartId.isNotEmpty) 'cart_id': cartId,
      if (cartId != null && cartId.isNotEmpty) 'cartId': cartId,
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
      'container_price': containerPrice,
      'is_extra_addon': isExtraAddon,
      'menu_name': menuName,
      if (quantity != 1) 'quantity': quantity,
      if (description != null && description.isNotEmpty) 'description': description,
    });
  }

  /// POST /restaurant/cart/updatecartmenuquantity
  Future<ApiEnvelope> updateCartItemQuantity({
    required String cartId,
    required String cartmenuId,
    required int quantity,
    String? taxId,
    String? taxValueType,
    String? taxValueAmount,
    String containerPrice = '0',
  }) {
    return _client.post(ApiConfig.updateCartQty, body: {
      'cartId': cartId,
      'cartmenuId': cartmenuId,
      'quantity': quantity,
      'tax_id': taxId,
      'tax_value_type': taxValueType,
      'tax_value_amount': taxValueAmount,
      'container_price': containerPrice,
    });
  }

  /// DELETE /restaurant/cart/deletemenu?cartId=&cartmenuId=&… (un-KOT'd lines only;
  /// deleting the last line deletes the cart and frees the table).
  Future<ApiEnvelope> deleteCartMenuItem({
    required String cartId,
    required String cartmenuId,
    String? taxId,
    String? taxValueType,
    String? taxValueAmount,
    String containerPrice = '0',
  }) {
    return _client.delete(ApiConfig.deleteCartMenu, query: {
      'cartId': cartId,
      'cartmenuId': cartmenuId,
      'tax_id': taxId,
      'tax_value_type': taxValueType,
      'tax_value_amount': taxValueAmount,
      'container_price': containerPrice,
    });
  }

  /// POST /restaurant/cart/cancelmenu — the ONLY removal path for a KOT'd line.
  /// The row is kept with `cancel_status: 1` and excluded from pricing.
  Future<ApiEnvelope> cancelCartMenuItem({
    required String cartId,
    required String cartmenuId,
    required String reason,
    String? taxId,
    String? taxValueType,
    String? taxValueAmount,
    String containerPrice = '0',
  }) {
    return _client.post(ApiConfig.cancelCartMenu, body: {
      'cartId': cartId,
      'cartmenuId': cartmenuId,
      'tax_id': taxId,
      'tax_value_type': taxValueType,
      'tax_value_amount': taxValueAmount,
      'container_price': containerPrice,
      'cancel_status': '1',
      'cancel_reason': reason,
    });
  }

  // ============================================================
  // KOT / status / bill
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

  /// POST /restaurant/cart/setcartstatus { cartId, table_status }
  /// KOT → kot_status=1 on all lines (+ KDS fire); KOT_PRINT/PRINTED also set
  /// kotprint_status=1. Refused 422 `qr_order_awaiting_approval` while PENDING.
  Future<ApiEnvelope> setCartStatus({
    required String cartId,
    required String tableStatus,
  }) {
    return _client.post(ApiConfig.setCartStatus, body: {
      'cartId': cartId,
      'table_status': tableStatus,
    });
  }

  /// Fire kitchen (PENDING→KOT). Live path — never offline createorder.
  Future<ApiEnvelope> sendKotToKitchen({required String cartId}) =>
      setCartStatus(cartId: cartId, tableStatus: 'KOT');

  /// POST /restaurant/cart/setcarttobill { cartId, paymentType }
  /// This is the SETTLE: creates the Order + ledger row and hard-deletes the cart.
  /// Refusals (all HTTP 200): 404 invalid_id, 422 qr_order_awaiting_approval,
  /// 422 split_not_fully_paid, 422 split_total_changed.
  Future<ApiEnvelope> settleBill({
    required String cartId,
    required String paymentType,
  }) {
    return _client.post(ApiConfig.settleBill, body: {
      'cartId': cartId,
      'paymentType': normalizePaymentType(paymentType),
    });
  }

  // ============================================================
  // Discounts
  // ============================================================

  /// GET /restaurant/discount/avaliable?orderType=dinein&orderAmount=&searchName=
  Future<List<Map<String, dynamic>>> listAvailableDiscounts({
    required double orderAmount,
    String searchName = '',
  }) async {
    final env = await _client.get(ApiConfig.availableDiscounts, query: {
      'orderType': 'dinein',
      'orderAmount': orderAmount.toString(),
      'searchName': searchName,
    });
    return env.mapList;
  }

  /// POST /restaurant/cart/setcartdiscount { cartId, discount_id }
  Future<ApiEnvelope> setCartDiscount({
    required String cartId,
    required String discountId,
  }) {
    return _client.post(ApiConfig.setCartDiscount, body: {
      'cartId': cartId,
      'discount_id': discountId,
    });
  }

  /// POST /restaurant/cart/removecartdiscount { cartId }
  Future<ApiEnvelope> removeCartDiscount({required String cartId}) {
    return _client.post(ApiConfig.removeCartDiscount, body: {'cartId': cartId});
  }

  // ============================================================
  // Table actions
  // ============================================================

  /// PATCH /restaurant/cart/switchtable/{cartId} { table_id }
  Future<ApiEnvelope> switchTable({
    required String cartId,
    required String tableId,
  }) {
    return _client.patch(
      '${ApiConfig.switchTable}/$cartId',
      body: {'table_id': tableId},
    );
  }

  /// DELETE /restaurant/cart/deletecart/{cartId}
  /// Admin "Discard" — empties the table cart without settling (no Order/ledger).
  Future<ApiEnvelope> deleteCart(String cartId) {
    return _client.delete('${ApiConfig.releaseTable}/$cartId');
  }

  /// POST /restaurant/cart/qr-approval { cartId, action: ACCEPT|REJECT }
  Future<ApiEnvelope> decideQrOrder({
    required String cartId,
    required String action,
  }) {
    return _client.post(ApiConfig.qrApproval, body: {
      'cartId': cartId,
      'action': action,
    });
  }

  // ============================================================
  // Reservations & live orders (best-effort feeds)
  // ============================================================

  /// GET /restaurant/reservation/all?accepted_status=1
  Future<List<Map<String, dynamic>>> getReservations({
    String acceptedStatus = '1',
  }) async {
    final env = await _client.get(
      ApiConfig.getReservations,
      query: {'accepted_status': acceptedStatus, 'reservationNo': ''},
    );
    return env.mapList;
  }

  /// GET /restaurant/cart/listallcarts — NOT tenant-scoped on the backend, so
  /// carts are filtered client-side by restaurant_id and active status.
  Future<List<Map<String, dynamic>>> getLiveOrders() async {
    final restId = await _authService.getRestaurantId();
    final env = await _client.get(ApiConfig.getLiveCarts);
    const active = {'PENDING', 'RUNNING', 'KOT', 'KOT_PRINT', 'PRINTED'};
    final orders = <Map<String, dynamic>>[];
    for (final order in env.mapList) {
      final orderRest = order['restaurant_id']?.toString() ?? '';
      if (restId != null && restId.isNotEmpty && orderRest != restId) continue;
      final status = order['table_status']?.toString().toUpperCase() ?? '';
      if (status.isNotEmpty && !active.contains(status)) continue;
      final service = order['service_type']?.toString() ?? '';
      if (service.toLowerCase().contains('room')) continue;
      orders.add(order);
    }
    return orders;
  }
}
