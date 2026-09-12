import 'package:esc_pos_utils/esc_pos_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/table_model.dart';
import '../models/menu_model.dart';
import '../models/cart_model.dart';
import '../services/api_service.dart';
import '../services/thermal_printer_service.dart';

class PosProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  final ThermalPrinterService _printer = ThermalPrinterService();

  // ── Table State ──
  String? _activeTableId;
  String? _activeAreaId;
  Map<String, dynamic>? _tableDetails;
  DineInTable? _activeTable;

  // ── Menu State ──
  List<MenuCategory> _categories = [];
  List<MenuItem> _allItems = [];
  String? _selectedCategoryId; // null = 'ALL'
  String _searchQuery = '';

  // ── Cart State (fetched live from backend) ──
  List<Map<String, dynamic>> _cartData = []; // Raw backend cart data
  final List<CartLineItem> _cartLines = []; // Legacy local cart lines

  // ── Tax State ──
  List<Map<String, dynamic>> _taxConfig = [];
  Map<String, dynamic>? _consolidatedTax; // Merged tax entry

  // ── Loading ──
  bool _isLoading = false;
  String? _errorMessage;

  // ── Printer ──
  Map<String, dynamic> _printerSettings = {};

  // ============================================================
  // Getters
  // ============================================================

  String? get activeTableId => _activeTableId;
  String? get activeAreaId => _activeAreaId;
  Map<String, dynamic>? get tableDetails => _tableDetails;
  DineInTable? get activeTable => _activeTable;

  List<MenuCategory> get categories => _categories;
  String? get selectedCategoryId => _selectedCategoryId;
  String get searchQuery => _searchQuery;
  List<CartLineItem> get cartLines => _cartLines;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  Map<String, dynamic> get printerSettings => _printerSettings;
  List<Map<String, dynamic>> get cartData => _cartData;
  Map<String, dynamic>? get consolidatedTax => _consolidatedTax;

  /// The table_id as stored in the backend (from tableDetails or model).
  String get resolvedTableId {
    return _tableDetails?['table_id']?.toString() ??
        _activeTable?.id ??
        _activeTableId ??
        '';
  }

  // ── Filtered menu items ──
  List<MenuItem> get filteredMenuItems {
    var result = List<MenuItem>.from(_allItems);

    if (_selectedCategoryId != null && _selectedCategoryId!.isNotEmpty) {
      // Filter by category name match (web uses valuename/displayname)
      final selectedCat = _categories.firstWhere(
        (c) => c.id == _selectedCategoryId,
        orElse: () => MenuCategory(id: '', categoryName: ''),
      );
      if (selectedCat.id.isNotEmpty) {
        result = result.where((item) {
          // Match by categoryId first, then by name
          if (item.categoryId == _selectedCategoryId) return true;
          // Also match by category name in item's categories array
          return false;
        }).toList();
      }
    }

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase().trim();
      result = result.where((item) {
        final nameMatch = item.name.toLowerCase().contains(q);
        final displayMatch =
            item.displayName?.toLowerCase().contains(q) ?? false;
        final codeMatch = item.shortCode?.toLowerCase().contains(q) ?? false;
        return nameMatch || displayMatch || codeMatch;
      }).toList();
    }

    // Sort alphabetically by display name
    result.sort(
      (a, b) => (a.displayName ?? a.name).compareTo(b.displayName ?? b.name),
    );

    return result;
  }

  // ── Cart computed values from backend data ──
  List<Map<String, dynamic>> get cartMenuItems {
    if (_cartData.isEmpty) return [];
    final cart = _cartData[0];
    final items = cart['cartMenuData'];
    if (items is List) {
      return List<Map<String, dynamic>>.from(
        items.where((i) => i['cancel_status'] != 1),
      );
    }
    return [];
  }

  double get subTotal {
    if (_cartData.isEmpty) return 0.0;
    final cart = _cartData[0];
    return double.tryParse(cart['menu_total']?.toString() ?? '0') ?? 0.0;
  }

  double get taxAmount {
    if (_cartData.isEmpty) return 0.0;
    final cart = _cartData[0];
    return double.tryParse(cart['tax_price']?.toString() ?? '0') ?? 0.0;
  }

  double get grandTotal {
    if (_cartData.isEmpty) return 0.0;
    final cart = _cartData[0];
    return double.tryParse(
          cart['grand_total']?.toString() ??
              cart['bill_total']?.toString() ??
              '0',
        ) ??
        0.0;
  }

  int get totalItemCount {
    return cartMenuItems.fold(
      0,
      (sum, item) =>
          sum + (int.tryParse(item['quantity']?.toString() ?? '1') ?? 1),
    );
  }

  String get cartId {
    if (_cartData.isEmpty) return '';
    return _cartData[0]['_id']?.toString() ?? '';
  }

  /// Bill Totals for display
  double get subTotalLegacy =>
      _cartLines.fold(0.0, (sum, line) => sum + line.lineTotal);
  double get taxAmountLegacy => subTotalLegacy * 0.05;
  double get grandTotalLegacy => subTotalLegacy + taxAmountLegacy;
  int get totalItemCountLegacy =>
      _cartLines.fold(0, (sum, line) => sum + line.quantity);

  // ============================================================
  // Actions
  // ============================================================

  void setActiveTable(DineInTable table) {
    _activeTable = table;
    _activeTableId = table.id;
    _activeAreaId = table.areaId;
    _cartLines.clear();
    _cartData = [];
    notifyListeners();
  }

  void selectCategory(String? categoryId) {
    _selectedCategoryId = categoryId;
    notifyListeners();

    // Background fetch for the selected category (like web's clickcategory)
    if (categoryId != null && categoryId.isNotEmpty) {
      _apiService
          .getMenuItemsByCategory(categoryId: categoryId, search: _searchQuery)
          .then((items) {
            // Only update if the category hasn't changed while fetching
            if (_selectedCategoryId == categoryId && items.isNotEmpty) {
              // Merge with existing items (don't replace the full cache)
              notifyListeners();
            }
          });
    }
  }

  void setSearchQuery(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  // ============================================================
  // Data Loading (matching web panel's ngOnInit flow)
  // ============================================================

  /// Load everything needed for the food categories screen.
  /// Called when user taps a table — mirrors web's ngOnInit chain.
  Future<void> loadTableAndMenu(String tableId, String areaId) async {
    _isLoading = true;
    _errorMessage = null;
    _activeTableId = tableId;
    _activeAreaId = areaId;
    notifyListeners();

    try {
      // Parallel fetch: categories + menu items + table details + tax
      final results = await Future.wait([
        _apiService.getActiveCategories(), // 0: categories
        _apiService.getMenuItemsByCategory(), // 1: all dinein menu items
        _apiService.viewTableById(tableId), // 2: table details
        _apiService.getTaxConfig(), // 3: tax config
        _apiService.getPrinterSettings(), // 4: printer settings
      ]);

      _categories = results[0] as List<MenuCategory>;
      _allItems = results[1] as List<MenuItem>;
      _tableDetails = results[2] as Map<String, dynamic>?;
      _taxConfig = results[3] as List<Map<String, dynamic>>;
      _printerSettings = results[4] as Map<String, dynamic>;

      // Build consolidated tax (sum all tax values — matches web's setTax logic)
      if (_taxConfig.isNotEmpty) {
        double totalTaxValue = 0;
        for (var t in _taxConfig) {
          totalTaxValue +=
              double.tryParse(t['value_amount']?.toString() ?? '0') ?? 0;
        }
        _consolidatedTax = {
          ..._taxConfig[0],
          'value_amount': totalTaxValue.toString(),
        };
      }

      debugPrint(
        '[Fatfox POS] Loaded: ${_categories.length} categories, '
        '${_allItems.length} menu items, '
        'table: ${_tableDetails?['table_number']}, '
        '${_taxConfig.length} tax entries',
      );

      // Now fetch cart items using the resolved table_id
      final resolvedId = _tableDetails?['table_id']?.toString() ?? tableId;
      await _reloadCartData(resolvedId);
    } catch (e) {
      debugPrint('[Fatfox POS] Load error: $e');
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Legacy loadMenuData for backward compat with PosOrderingScreen
  Future<void> loadMenuData() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final catList = await _apiService.getCategories();
      final itemList = await _apiService.getMenuItems();
      final pSettings = await _apiService.getPrinterSettings();
      _categories = catList;
      _allItems = itemList;
      _printerSettings = pSettings;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }

    _isLoading = false;
    notifyListeners();
  }

  // ============================================================
  // Cart Operations (live backend — matching web panel)
  // ============================================================

  /// Reload cart data from backend.
  Future<void> _reloadCartData(String tableId) async {
    try {
      _cartData = await _apiService.getCartItemsByTableId(tableId);
      debugPrint(
        '[Fatfox POS] Cart reloaded: ${_cartData.length} carts, '
        '${cartMenuItems.length} items, total: ₹$grandTotal',
      );
    } catch (e) {
      debugPrint('[Fatfox POS] Cart reload error: $e');
    }
  }

  /// Reload cart (public, uses resolved table ID).
  Future<void> reloadCart() async {
    final tid = resolvedTableId;
    if (tid.isEmpty) return;
    await _reloadCartData(tid);
    notifyListeners();
  }

  /// Add a menu item to cart via backend (mirrors web's addItem flow).
  Future<bool> addItemToCart(
    MenuItem item, {
    String? variantId,
    List<Map<String, dynamic>>? addons,
  }) async {
    final tid = resolvedTableId;
    if (tid.isEmpty) return false;

    _isLoading = true;
    notifyListeners();

    try {
      MenuVariant? selectedVariant;
      for (final variant in item.variants) {
        if (variant.id == variantId) {
          selectedVariant = variant;
          break;
        }
      }
      final addonTotal = (addons ?? []).fold<double>(
        0,
        (sum, addon) =>
            sum +
            (double.tryParse(addon['addon_price']?.toString() ?? '0') ?? 0),
      );
      final menuPrice = (selectedVariant?.price ?? item.price) + addonTotal;

      final result = await _apiService.createCartItem(
        tableId: tid,
        menuId: item.id,
        menuPrice: menuPrice,
        variantId: variantId,
        addons: addons,
        taxId: _consolidatedTax?['_id']?.toString(),
        taxName: _consolidatedTax?['name']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
      );

      final statusCode = result['status']?['code'];
      if (statusCode == 200) {
        await _reloadCartData(tid);
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage =
            result['status']?['message']?.toString() ?? 'Failed to add item';
      }
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  /// Update quantity of a cart menu item via backend.
  Future<bool> updateItemQuantity(
    String cartItemId,
    String cartmenuId,
    int newQty,
  ) async {
    try {
      if (newQty <= 0) {
        return await removeCartItem(cartItemId, cartmenuId);
      }

      final result = await _apiService.updateCartItemQuantity(
        cartId: cartItemId,
        cartmenuId: cartmenuId,
        quantity: newQty,
        taxId: _consolidatedTax?['_id']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
      );

      final statusCode = result['status']?['code'];
      if (statusCode == 200) {
        await reloadCart();
        return true;
      }
    } catch (e) {
      debugPrint('[Fatfox POS] UpdateQty error: $e');
    }
    return false;
  }

  /// Remove a cart menu item via backend.
  Future<bool> removeCartItem(String cartItemId, String cartmenuId) async {
    try {
      final result = await _apiService.deleteCartMenuItem(
        cartId: cartItemId,
        cartmenuId: cartmenuId,
        taxId: _consolidatedTax?['_id']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
      );

      final statusCode = result['status']?['code'];
      if (statusCode == 200) {
        await reloadCart();
        return true;
      }
    } catch (e) {
      debugPrint('[Fatfox POS] RemoveItem error: $e');
    }
    return false;
  }

  /// Cart lines shaped for ESC/POS (from live backend cart).
  List<CartLineItem> get printCartLines {
    return cartMenuItems.map((m) {
      final name =
          m['menu_name']?.toString() ??
          m['name']?.toString() ??
          m['displayname']?.toString() ??
          'Item';
      final variantName = m['variant_name']?.toString() ??
          m['valuename']?.toString();
      return CartLineItem(
        id: m['_id']?.toString() ?? '',
        item: MenuItem(
          id: m['menu_id']?.toString() ?? '',
          categoryId: m['category_id']?.toString() ?? '',
          name: name,
          attribute: m['attribute']?.toString() ?? 'VEG',
          price:
              double.tryParse(m['menu_price']?.toString() ?? '0') ?? 0.0,
        ),
        quantity: int.tryParse(m['quantity']?.toString() ?? '1') ?? 1,
        selectedVariant: (variantName != null && variantName.isNotEmpty)
            ? MenuVariant(
                id: m['variant_id']?.toString() ?? '',
                name: variantName,
                price:
                    double.tryParse(m['menu_price']?.toString() ?? '0') ??
                    0.0,
              )
            : null,
        instruction: m['description']?.toString(),
      );
    }).toList();
  }

  Future<PaperSize> _paperSizeFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final paper = prefs.getString('printer_paper') ?? '80mm';
    return paper.contains('58') ? PaperSize.mm58 : PaperSize.mm80;
  }

  String get _restaurantHeader {
    final fromApi = _printerSettings['restaurant_name']?.toString();
    if (fromApi != null && fromApi.isNotEmpty) return fromApi;
    return 'THE FAT FOX';
  }

  /// Map viewmenu / cartmenu rows into ESC/POS cart lines.
  List<CartLineItem> _kotLinesFromMaps(List<Map<String, dynamic>> items) {
    return items.map((m) {
      final menu = m['menu'];
      final menuMap = menu is Map ? Map<String, dynamic>.from(menu) : null;
      final name = m['menu_name']?.toString() ??
          menuMap?['displayname']?.toString() ??
          menuMap?['name']?.toString() ??
          m['name']?.toString() ??
          m['displayname']?.toString() ??
          'Item';
      final variant = m['variant'];
      final variantMap =
          variant is Map ? Map<String, dynamic>.from(variant) : null;
      final variantName = m['variant_name']?.toString() ??
          variantMap?['valuename']?.toString() ??
          variantMap?['name']?.toString() ??
          m['valuename']?.toString();
      return CartLineItem(
        id: m['_id']?.toString() ?? '',
        item: MenuItem(
          id: m['menu_id']?.toString() ?? menuMap?['_id']?.toString() ?? '',
          categoryId: m['category_id']?.toString() ?? '',
          name: name,
          attribute: m['attribute']?.toString() ??
              menuMap?['attribute']?.toString() ??
              'VEG',
          price: double.tryParse(
                m['menu_price']?.toString() ??
                    m['individual_price']?.toString() ??
                    '0',
              ) ??
              0.0,
        ),
        quantity: int.tryParse(m['quantity']?.toString() ?? '1') ?? 1,
        selectedVariant: (variantName != null && variantName.isNotEmpty)
            ? MenuVariant(
                id: m['variant_id']?.toString() ??
                    variantMap?['_id']?.toString() ??
                    '',
                name: variantName,
                price: double.tryParse(
                      m['menu_price']?.toString() ??
                          m['individual_price']?.toString() ??
                          '0',
                    ) ??
                    0.0,
              )
            : null,
        instruction: m['description']?.toString(),
      );
    }).toList();
  }

  /// Send KOT to kitchen via setcartstatus, then silent-print LAN ESC/POS.
  /// Returns true if KOT API succeeded. [printError] set if API ok but print failed.
  /// KOT_PRINT is only sent after a successful print.
  String? printError;

  Future<bool> sendKotOrder() async {
    final tid = resolvedTableId;
    final cid = cartId;
    if (tid.isEmpty || cid.isEmpty) return false;

    _isLoading = true;
    printError = null;
    notifyListeners();

    try {
      // 1) Fire kitchen / accept PENDING→KOT
      final result = await _apiService.sendKotToKitchen(cartId: cid);
      final statusCode = result['status']?['code'];
      if (statusCode != 200) {
        _errorMessage =
            result['status']?['message']?.toString() ?? 'KOT failed';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      // 2) Reload cart after KOT step
      await reloadCart();

      // 3) Print lines from viewmenu status=kot (fallback to live cart lines)
      List<CartLineItem> kotItems = [];
      try {
        final kotRows = await _apiService.getKotViewMenu(tableId: tid);
        if (kotRows.isNotEmpty) {
          kotItems = _kotLinesFromMaps(kotRows);
        }
      } catch (e) {
        debugPrint('[Fatfox POS] getKotViewMenu error: $e');
      }
      if (kotItems.isEmpty) {
        kotItems = printCartLines;
      }

      // 4) LAN print
      var printOk = false;
      try {
        final table = _activeTable ??
            DineInTable(
              id: tid,
              tableNumber: _tableDetails?['table_number']?.toString() ??
                  _tableDetails?['name']?.toString() ??
                  tid,
              areaId: _activeAreaId ?? '',
              noOfPeople: 0,
              tableStatus: 'KOT',
              status: '1',
              totalPrice: grandTotal,
              itemCount: totalItemCount,
            );
        final prefs = await SharedPreferences.getInstance();
        final header =
            prefs.getString('printer_header') ?? _restaurantHeader;
        final bytes = await _printer.generateKotBytes(
          table: table,
          items: kotItems,
          restaurantName: header,
          paperSize: await _paperSizeFromPrefs(),
        );
        await _printer.printBytes(bytes);
        printOk = true;
      } catch (e) {
        printError = e.toString().replaceAll('Exception: ', '');
        debugPrint('[Fatfox POS] KOT print error: $e');
      }

      // 5) Mark KOT_PRINT only after successful print
      if (printOk) {
        try {
          final printStatus = await _apiService.setCartStatus(
            cartId: cid,
            tableStatus: 'KOT_PRINT',
          );
          final printCode = printStatus['status']?['code'];
          if (printCode != 200) {
            debugPrint(
              '[Fatfox POS] KOT_PRINT status failed: '
              '${printStatus['status']?['message']}',
            );
          } else {
            await reloadCart();
          }
        } catch (e) {
          debugPrint('[Fatfox POS] KOT_PRINT error: $e');
        }
      }

      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  /// Available dine-in discounts for the current cart total.
  Future<List<Map<String, dynamic>>> listDiscounts({
    String searchName = '',
  }) async {
    final amount = grandTotal > 0 ? grandTotal : subTotal;
    try {
      return await _apiService.listAvailableDiscounts(
        orderAmount: amount,
        searchName: searchName,
      );
    } catch (e) {
      debugPrint('[Fatfox POS] listDiscounts error: $e');
      return [];
    }
  }

  /// Apply discount then reload cart.
  Future<bool> applyDiscount(String discountId) async {
    final cid = cartId;
    if (cid.isEmpty || discountId.isEmpty) return false;

    try {
      final result = await _apiService.setCartDiscount(
        cartId: cid,
        discountId: discountId,
      );
      final statusCode = result['status']?['code'];
      if (statusCode == 200) {
        await reloadCart();
        return true;
      }
      _errorMessage =
          result['status']?['message']?.toString() ?? 'Discount failed';
      notifyListeners();
    } catch (e) {
      debugPrint('[Fatfox POS] applyDiscount error: $e');
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
    }
    return false;
  }

  /// Remove cart discount then reload cart.
  Future<bool> clearDiscount() async {
    final cid = cartId;
    if (cid.isEmpty) return false;

    try {
      final result = await _apiService.removeCartDiscount(cartId: cid);
      final statusCode = result['status']?['code'];
      if (statusCode == 200) {
        await reloadCart();
        return true;
      }
      _errorMessage =
          result['status']?['message']?.toString() ?? 'Remove discount failed';
      notifyListeners();
    } catch (e) {
      debugPrint('[Fatfox POS] clearDiscount error: $e');
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
    }
    return false;
  }

  /// Settle bill via API then silent-print customer receipt.
  Future<bool> settleAndPrintBill({String paymentType = 'CASH'}) async {
    final tid = resolvedTableId;
    final cid = cartId;
    if (tid.isEmpty || cid.isEmpty) {
      _errorMessage = 'No active cart for this table';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    printError = null;
    notifyListeners();

    try {
      final result = await _apiService.settleBill(
        cartId: cid,
        tableId: tid,
        paymentType: paymentType,
      );
      final statusCode = result['status']?['code'];
      final ok = statusCode == 200 || statusCode == null && result.isNotEmpty;
      if (!ok && statusCode != null && statusCode != 200) {
        _errorMessage =
            result['status']?['message']?.toString() ?? 'Settle failed';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      try {
        final table = _activeTable ??
            DineInTable(
              id: tid,
              tableNumber: _tableDetails?['table_number']?.toString() ??
                  _tableDetails?['name']?.toString() ??
                  tid,
              areaId: _activeAreaId ?? '',
              noOfPeople: 0,
              tableStatus: 'PRINTED',
              status: '1',
              totalPrice: grandTotal,
              itemCount: totalItemCount,
            );
        final prefs = await SharedPreferences.getInstance();
        final header =
            prefs.getString('printer_header') ?? _restaurantHeader;
        final bytes = await _printer.generateBillBytes(
          table: table,
          items: printCartLines,
          subTotal: subTotal,
          taxAmount: taxAmount,
          grandTotal: grandTotal > 0 ? grandTotal : (subTotal + taxAmount),
          restaurantName: header,
          paperSize: await _paperSizeFromPrefs(),
        );
        await _printer.printBytes(bytes);
      } catch (e) {
        printError = e.toString().replaceAll('Exception: ', '');
        debugPrint('[Fatfox POS] Bill print error: $e');
      }

      await reloadCart();
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  // ============================================================
  // Legacy Cart Operations (for PosOrderingScreen backward compat)
  // ============================================================

  void addToCart(
    MenuItem item, {
    MenuVariant? variant,
    List<MenuAddon>? addons,
    String? instruction,
  }) {
    final existingIndex = _cartLines.indexWhere(
      (line) =>
          line.item.id == item.id &&
          line.selectedVariant?.id == variant?.id &&
          !line.isKotPrinted,
    );

    if (existingIndex >= 0) {
      _cartLines[existingIndex].quantity += 1;
    } else {
      _cartLines.add(
        CartLineItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          item: item,
          quantity: 1,
          selectedVariant: variant,
          selectedAddons: addons ?? [],
          instruction: instruction,
        ),
      );
    }
    notifyListeners();
  }

  void updateQuantity(CartLineItem line, int newQty) {
    if (newQty <= 0) {
      _cartLines.removeWhere((l) => l.id == line.id);
    } else {
      line.quantity = newQty;
    }
    notifyListeners();
  }

  void removeLine(CartLineItem line) {
    _cartLines.removeWhere((l) => l.id == line.id);
    notifyListeners();
  }

  void clearCart() {
    _cartLines.clear();
    _cartData = [];
    notifyListeners();
  }

  Future<bool> sendKot() async {
    if (_activeTable == null || _cartLines.isEmpty) return false;

    _isLoading = true;
    notifyListeners();

    try {
      final payloadItems = _cartLines.map((l) => l.toCartJson()).toList();
      final addRes = await _apiService.addToCart(
        tableId: _activeTable!.id,
        menuItems: payloadItems,
      );

      final cId = addRes['data']?['_id'] ?? addRes['cart_id'];
      if (cId != null) {
        await _apiService.createKot(
          tableId: _activeTable!.id,
          cartId: cId.toString(),
        );
        for (var line in _cartLines) {
          line.isKotPrinted = true;
        }
        _isLoading = false;
        notifyListeners();
        return true;
      }
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }
}
