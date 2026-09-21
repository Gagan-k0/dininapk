class ApiConfig {
  static String baseUrl = 'https://backend.fatfox.testfox.in/api/v1'; // Live Server API URL with v1 prefix

  static String get cleanBaseUrl {
    var url = baseUrl.trim().replaceAll(',', '');
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (!url.contains('/api/v1') && !url.contains('/api/')) {
      if (url.endsWith('/api')) {
        url = '$url/v1';
      } else {
        url = '$url/api/v1';
      }
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  // Authentication (same endpoints as fatfox-admin-panel)
  static String restaurantLogin = '/restaurant/login';
  static String staffLogin = '/restaurant/staff-login';
  static String login = '/user/login'; // not used for waiter POS

  // Subscription — never refused by the lock middleware.
  static String subscriptionStatus = '/restaurant/subscription/status';

  /// Raw 32-byte Ed25519 public key (base64) that verifies offline licences.
  /// Build config so it can be rotated: --dart-define=SUBSCRIPTION_PUBLIC_KEY=…
  static const String subscriptionPublicKey = String.fromEnvironment(
    'SUBSCRIPTION_PUBLIC_KEY',
    defaultValue: 'xXsgsz5LPgJaQfw7WU1KBRY4j4QVhjKXXDQixmeN56Y=',
  );

  // Table Management & Areas — search parameters are required by backend regex match
  static String getAllTables = '/restaurant/table/all?searchNumber=';
  static String getAreaList =
      '/restaurant/table/area/all-avaliable?searchName=';
  static String releaseTable = '/restaurant/cart/deletecart'; // + /{cartId}
  static String switchTable = '/restaurant/cart/switchtable'; // + /{cartId}
  static String viewTable = '/restaurant/table/view'; // + /{tableId}

  // Menu & Categories
  static String getCategories = '/restaurant/category/all';
  static String getActiveCategories =
      '/restaurant/category/active-all?searchName=';
  static String getActiveCategoriesPath = '/restaurant/category/active-all';
  static String getAllMenu = '/restaurant/menu/all';
  static String getMenuByCategory = '/restaurant/menu/by-category-itemin'; // ?categoryId=&searchItemIn=dinein&searchName=
  static String viewMenuById = '/restaurant/menu/getmenu'; // + /{menuId}
  /// Backend spelling is "avaliable". Extra Add-ons rail (admin AllAvailableAddons).
  static String allAvailableAddons =
      '/restaurant/add-on/all-avaliable'; // ?searchName=
  /// Admin AllVariants — join names onto getmenu variant_id rows.
  static String allVariants = '/restaurant/variant/all'; // ?searchName=
  /// Admin & Waiter Kitchen Departments (KOT stations)
  static String kitchenDepartments = '/restaurant/kitchen-department';

  // Restaurant & Printer Settings
  static String getRestaurantView = '/restaurant/view';
  /// Same endpoint the admin exe/website read for `printer_settings` (and
  /// everything else on the Restaurant Settings page).
  static String restaurantSettingsView = '/restaurant/settings/view';
  /// Only `printer_settings`, readable by any staff — waiter accounts lack the
  /// `private` permission [restaurantSettingsView] requires.
  static String printerSettings = '/restaurant/settings/printer-settings';
  /// Same endpoint the admin exe/website PUT `receipt_settings`/`printer_config`
  /// to — shared source of truth across every device for one restaurant.
  static String updatePrinterSettings =
      '/restaurant/settings/update-printer-settings';

  // Tax Configuration
  static String getTaxConfig =
      '/restaurant/tax/settax'; // ?area_id=&area_type=dinein

  // Orders, Cart & KOT
  static String addToCart = '/restaurant/cart/createcart';
  static String getCartDetails =
      '/restaurant/cart/listallcartmenus'; // ?tableId=
  static String updateCartQty = '/restaurant/cart/updatecartmenuquantity';
  /// Batch of unsent draft lines, keyed by `Idempotency-Key`.
  static String offlineSync = '/restaurant/cart/offline-sync';
  /// Bills a sitting that was captured offline, backdated to `captured_at` so
  /// the revenue lands on the day it was taken. Keyed by `Idempotency-Key`.
  static String offlineSettle = '/restaurant/cart/offline-settle';
  /// Applies a KOT/bill status for a print that ALREADY happened on paper.
  /// Unlike [setCartStatus] it never fires the kitchen display or a push —
  /// the food was cooked from that ticket hours ago. Keyed by
  /// `Idempotency-Key`; `captured_at` must be genuinely in the past.
  static String offlineStatus = '/restaurant/cart/offline-status';
  /// Frees this table's device claim so this tablet can send (waiter-confirmed).
  static String releaseTableClaim = '/restaurant/cart/table-claim/release';
  static String deleteCartMenu =
      '/restaurant/cart/deletemenu'; // ?cartId=&cartmenuId=&...
  /// Offline sync only — live KOT must use [setCartStatus], not createorder.
  static String createKot = '/restaurant/cart/createorder';
  /// Live dine-in kitchen / print status (PENDING→KOT, then KOT_PRINT).
  static String setCartStatus = '/restaurant/cart/setcartstatus';
  static String kotPrintView =
      '/restaurant/cart/viewmenu'; // ?tableId=&status=kot|all|reprint
  /// Cart header + restaurant doc for the printed bill.
  static String billView = '/restaurant/cart/vieworder-save'; // ?tableId=
  /// Cancel (not delete) a KOT'd line — keeps the row with cancel_status=1.
  static String cancelCartMenu = '/restaurant/cart/cancelmenu';
  static String settleBill = '/restaurant/cart/setcarttobill';
  static String setCartDiscount = '/restaurant/cart/setcartdiscount';
  static String removeCartDiscount = '/restaurant/cart/removecartdiscount';
  /// Backend spelling is "avaliable" (not "available").
  static String availableDiscounts = '/restaurant/discount/avaliable';
  static String getLiveCarts = '/restaurant/cart/listallcarts';
  static String getReservations = '/restaurant/reservation/all'; // ?accepted_status=
  /// Staff accept/reject first QR dine-in order awaiting approval.
  static String qrApproval = '/restaurant/cart/qr-approval';

  // Orders (settled) — for transaction reports / CSV export
  static String orderList = '/restaurant/order';
  static String orderView = '/restaurant/order/vieworder';

  static Map<String, String> headers(
    String? token,
    String? restaurantId, {
    String? deviceId,
  }) {
    final Map<String, String> h = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (token != null && token.isNotEmpty) {
      h['Authorization'] = 'Bearer $token';
    }
    if (restaurantId != null && restaurantId.isNotEmpty) {
      h['x-restaurant-id'] = restaurantId;
    }
    // Server table claim reads x-device-id; without it every tablet on the same
    // staff login shares one claim (helpers/tableClaim.js deviceIdFromRestaurantReq).
    if (deviceId != null && deviceId.isNotEmpty) {
      h['x-device-id'] = deviceId;
    }
    return h;
  }
}
