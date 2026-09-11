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

  // Authentication
  static String login = '/user/login';
  static String restaurantLogin = '/restaurant/login';

  // Table Management & Areas — search parameters are required by backend regex match
  static String getAllTables = '/restaurant/table/all?searchNumber=';
  static String getAreaList = '/restaurant/table/area/all-avaliable?searchName=';
  static String releaseTable = '/restaurant/cart/deletecart';
  static String switchTable = '/restaurant/cart/switchtable';
  static String viewTable = '/restaurant/table/view'; // + /{tableId}

  // Menu & Categories
  static String getCategories = '/restaurant/category/all';
  static String getActiveCategories = '/restaurant/category/active-all?searchName=';
  static String getAllMenu = '/restaurant/menu/all';
  static String getMenuByCategory = '/restaurant/menu/by-category-itemin'; // ?categoryId=&searchItemIn=dinein&searchName=
  static String viewMenuById = '/restaurant/menu/getmenu'; // + /{menuId}

  // Restaurant & Printer Settings
  static String getRestaurantView = '/restaurant/view';

  // Tax Configuration
  static String getTaxConfig = '/restaurant/tax/settax'; // ?area_id=&area_type=dinein

  // Orders, Cart & KOT
  static String addToCart = '/restaurant/cart/createcart';
  static String getCartDetails = '/restaurant/cart/listallcartmenus'; // ?tableId=
  static String updateCartQty = '/restaurant/cart/updatecartmenuquantity';
  static String deleteCartMenu = '/restaurant/cart/deletemenu'; // ?cartId=&cartmenuId=&...
  static String createKot = '/restaurant/cart/createorder';
  static String kotPrintView = '/restaurant/cart/viewmenu'; // ?tableId=&status=1
  static String settleBill = '/restaurant/cart/setcarttobill';
  static String getLiveCarts = '/restaurant/cart/listallcarts';
  static String getReservations = '/restaurant/reservation/all';

  static Map<String, String> headers(String? token, String? restaurantId) {
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
    return h;
  }
}
