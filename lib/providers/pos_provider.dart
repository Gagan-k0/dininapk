import 'package:flutter/foundation.dart';

import '../models/table_model.dart';
import '../models/menu_model.dart';
import '../models/cart_model.dart';
import '../services/api_service.dart';
import '../services/bill_builder.dart';
import '../services/thermal_printer_service.dart';

/// Ordering screen state for ONE open table. Mirrors the admin
/// `dinein-food-categories` contract:
/// * every cart write goes to the live backend and repaints from the response;
/// * `container_price` is echoed on every write (the server resets it to 0 otherwise);
/// * quantity is locked once a line is KOT'd — removal is `cancelmenu` with a reason;
/// * KOT = `setcartstatus KOT` → print → `KOT_PRINT` only after a successful print;
/// * Bill = print → `setcartstatus PRINTED`; Settle = `setcarttobill` (deletes the cart).
class PosProvider with ChangeNotifier {
  final ApiService _apiService;
  final ThermalPrinterService _printer;

  PosProvider({ApiService? api, ThermalPrinterService? printer})
    : _apiService = api ?? ApiService(),
      _printer = printer ?? ThermalPrinterService();

  // ── Table ──
  String? _activeTableId;
  String? _activeAreaId;
  Map<String, dynamic>? _tableDetails;
  DineInTable? _activeTable;

  // ── Menu ──
  List<MenuCategory> _categories = [];
  List<MenuItem> _allItems = [];
  String? _selectedCategoryId; // null = 'ALL'
  String _searchQuery = '';

  // ── Cart (live backend snapshot) ──
  List<Map<String, dynamic>> _cartData = [];
  String? _cartError;

  // ── Tax ──
  List<Map<String, dynamic>> _taxConfig = [];
  Map<String, dynamic>? _consolidatedTax;

  // ── State ──
  bool _isLoading = false; // screen-level load
  bool _isBusy = false; // a cart write / print in flight
  bool _sessionExpired = false;
  String? _errorMessage;
  String? printError;
  ReceiptPrefs? _receiptPrefs;

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
  bool get isLoading => _isLoading;
  bool get isBusy => _isBusy;
  bool get sessionExpired => _sessionExpired;
  String? get errorMessage => _errorMessage;
  String? get cartError => _cartError;
  List<Map<String, dynamic>> get cartData => _cartData;
  Map<String, dynamic>? get cart => _cartData.isEmpty ? null : _cartData.first;
  Map<String, dynamic>? get consolidatedTax => _consolidatedTax;
  List<Map<String, dynamic>> get taxConfig => _taxConfig;
  ReceiptPrefs? get receiptPrefs => _receiptPrefs;

  String get tableNumber =>
      _tableDetails?['table_number']?.toString() ??
      _activeTable?.tableNumber ??
      '';

  /// Live cart status (BLANK when there is no cart yet).
  String get tableStatus =>
      cart?['table_status']?.toString() ??
      _tableDetails?['table_status']?.toString() ??
      'BLANK';

  /// The table_id as stored in the backend (from tableDetails or model).
  String get resolvedTableId {
    return _tableDetails?['table_id']?.toString() ??
        _activeTable?.id ??
        _activeTableId ??
        '';
  }

  List<MenuItem> get filteredMenuItems {
    var result = List<MenuItem>.from(_allItems);

    if (_selectedCategoryId != null && _selectedCategoryId!.isNotEmpty) {
      result = result
          .where((i) => i.categoryId == _selectedCategoryId)
          .toList();
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

    result.sort(
      (a, b) => (a.displayName ?? a.name).compareTo(b.displayName ?? b.name),
    );
    return result;
  }

  // ── Cart computed values (cancelled rows excluded everywhere) ──
  List<Map<String, dynamic>> get cartMenuItems {
    final items = cart?['cartMenuData'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .where((i) => i['cancel_status'] != 1 && i['cancel_status'] != '1')
        .map((i) => Map<String, dynamic>.from(i))
        .toList();
  }

  bool get hasUnsentKotItems =>
      cartMenuItems.any((i) => i['kot_status'] != 1 && i['kot_status'] != '1');

  /// KOT reached the kitchen but has not been confirmed as physically printed.
  /// This remains true after a printer failure so KOT PRINT can be retried.
  bool get hasUnprintedItems => cartMenuItems.any(
    (i) => i['kotprint_status'] != 1 && i['kotprint_status'] != '1',
  );

  bool get hasKotItems =>
      cartMenuItems.any((i) => i['kot_status'] == 1 || i['kot_status'] == '1');

  double get subTotal => _num(cart?['food_subtotal']) > 0
      ? _num(cart?['food_subtotal'])
      : _num(cart?['menu_total']);
  double get taxAmount => _num(cart?['tax_price']);
  double get discountAmount => _num(cart?['discount_price']);
  String? get discountName => cart?['discount_name']?.toString();
  double get containerCharge => _num(cart?['container_price']);
  double get areaCharge => _num(cart?['area_charge']);
  double get roundOff => _num(cart?['round_off']);
  double get grandTotal => _num(cart?['total_price']);

  int get totalItemCount => cartMenuItems.fold(
    0,
    (sum, item) =>
        sum + (int.tryParse(item['quantity']?.toString() ?? '1') ?? 1),
  );

  String get cartId => cart?['_id']?.toString() ?? '';

  /// Phase 1 safety rule: Release only after the bill status is durable.
  bool get canRelease {
    if (cartId.isEmpty || cartMenuItems.isEmpty) return false;
    final s = tableStatus;
    return (s == 'PRINTED' || s == 'PAID') &&
        !hasUnsentKotItems &&
        !hasUnprintedItems;
  }

  String get releaseBlockedReason {
    if (cartId.isEmpty || cartMenuItems.isEmpty) {
      return 'No items on this table';
    }
    if (hasUnsentKotItems) return 'Send KOT for the new items first';
    if (hasUnprintedItems) return 'Print KOT before printing the bill';
    return 'Print the bill before releasing the table';
  }

  // ============================================================
  // Actions
  // ============================================================

  void setActiveTable(DineInTable table) {
    _activeTable = table;
    _activeTableId = table.id;
    _activeAreaId = table.areaId;
    _cartData = [];
    notifyListeners();
  }

  void selectCategory(String? categoryId) {
    _selectedCategoryId = categoryId;
    notifyListeners();
  }

  void setSearchQuery(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  // ============================================================
  // Loading (admin ngOnInit chain)
  // ============================================================

  /// Load everything the ordering screen needs. Table + categories + menu are
  /// mandatory; tax config is best-effort; the cart is loaded last and its
  /// failure is reported separately so the menu still renders.
  Future<void> loadTableAndMenu(String tableId, String areaId) async {
    _isLoading = true;
    _errorMessage = null;
    _cartError = null;
    _sessionExpired = false;
    _activeTableId = tableId;
    _activeAreaId = areaId;
    notifyListeners();

    try {
      _receiptPrefs = await ReceiptPrefs.load();
      final results = await Future.wait<Object?>([
        _apiService.viewTableById(tableId),
        _apiService.getActiveCategories(),
        _apiService.getMenuItemsByCategory(),
        _bestEffortTax(),
      ]);
      _tableDetails = results[0] as Map<String, dynamic>?;
      _categories = results[1] as List<MenuCategory>;
      _allItems = results[2] as List<MenuItem>;
      _taxConfig = results[3] as List<Map<String, dynamic>>;
      _buildConsolidatedTax();

      if (_tableDetails == null ||
          (_tableDetails!['table_id'] ?? _tableDetails!['_id']) == null) {
        _errorMessage = 'This table no longer exists. Go back to the floor.';
      } else {
        debugPrint(
          '[Fatfox POS] Loaded table ${_tableDetails?['table_number']}: '
          '${_categories.length} categories, ${_allItems.length} items, '
          '${_taxConfig.length} tax rows',
        );
        await _reloadCartData();
      }
    } on ApiException catch (e) {
      debugPrint('[Fatfox POS] Load refused: $e');
      _errorMessage = e.message;
      _sessionExpired = e.isAuth;
    } catch (e) {
      debugPrint('[Fatfox POS] Load error: $e');
      _errorMessage = friendlyError(e);
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> _bestEffortTax() async {
    try {
      return await _apiService.getTaxConfig();
    } on ApiException catch (e) {
      if (e.isAuth) rethrow;
      return const [];
    }
  }

  /// Admin sums every `settax` row into one `tax_value_amount`.
  void _buildConsolidatedTax() {
    if (_taxConfig.isEmpty) {
      _consolidatedTax = null;
      return;
    }
    double total = 0;
    for (final t in _taxConfig) {
      total += _num(t['value_amount']);
    }
    _consolidatedTax = {..._taxConfig.first, 'value_amount': total.toString()};
  }

  // ============================================================
  // Cart
  // ============================================================

  Future<void> _reloadCartData() async {
    final tid = resolvedTableId;
    if (tid.isEmpty) return;
    try {
      _cartData = await _apiService.getCartItemsByTableId(tid);
      _cartError = null;
      debugPrint(
        '[Fatfox POS] Cart: ${cartMenuItems.length} lines, total ₹$grandTotal, '
        'status $tableStatus',
      );
    } on ApiException catch (e) {
      _cartError = e.message;
      _sessionExpired = e.isAuth;
      debugPrint('[Fatfox POS] Cart reload refused: $e');
    } catch (e) {
      _cartError = friendlyError(e);
      debugPrint('[Fatfox POS] Cart reload error: $e');
    }
  }

  /// Public reload (used by the screen's refresh + after each write).
  Future<void> reloadCart() async {
    await _reloadCartData();
    notifyListeners();
  }

  /// Paints the cart from a write response when it carries the full snapshot
  /// (createcart / updatecartmenuquantity / deletemenu / cancelmenu all do),
  /// otherwise refetches.
  Future<void> _paintFromWrite(ApiEnvelope env) async {
    final list = env.mapList;
    final looksLikeSnapshot =
        list.isNotEmpty &&
        list.first.containsKey('cartMenuData') &&
        list.first.containsKey('total_price');
    if (looksLikeSnapshot) {
      _cartData = list;
      _cartError = null;
      return;
    }
    if (env.data == null || list.isEmpty) {
      // Cart may have been emptied (last line deleted) — confirm with a refetch.
      await _reloadCartData();
      return;
    }
    await _reloadCartData();
  }

  String get _containerPriceArg =>
      containerCharge > 0 ? containerCharge.toString() : '0';

  Future<bool> _write(Future<ApiEnvelope> Function() call) async {
    _isBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final env = await call();
      await _paintFromWrite(env);
      _isBusy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      _sessionExpired = e.isAuth;
    } catch (e) {
      _errorMessage = friendlyError(e);
    }
    _isBusy = false;
    notifyListeners();
    return false;
  }

  /// Add a menu item (admin `addItem` → createcart). The server merges into a
  /// matching un-KOT'd line, so re-adding a KOT'd item creates a NEW line for
  /// the next KOT — exactly as admin does.
  Future<bool> addItemToCart(
    MenuItem item, {
    String? variantId,
    List<Map<String, dynamic>>? addons,
    int quantity = 1,
    String? description,
  }) async {
    final tid = resolvedTableId;
    if (tid.isEmpty) {
      _errorMessage = 'Table not loaded';
      notifyListeners();
      return false;
    }

    MenuVariant? selectedVariant;
    for (final v in item.variants) {
      if (v.id == variantId) selectedVariant = v;
    }
    final addonTotal = (addons ?? []).fold<double>(
      0,
      (sum, a) => sum + _num(a['addon_price']),
    );
    final menuPrice = (selectedVariant?.price ?? item.price) + addonTotal;

    return _write(
      () => _apiService.createCartItem(
        tableId: tid,
        menuId: item.id,
        menuPrice: menuPrice,
        variantId: variantId,
        addons: addons,
        taxId: _consolidatedTax?['_id']?.toString(),
        taxName: _consolidatedTax?['name']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
        containerPrice: _containerPriceArg,
        quantity: quantity,
        description: description,
      ),
    );
  }

  /// Open-price / extra add-on line (admin "+ Custom"): no menu_id, typed price.
  Future<bool> addExtraItem({required String name, required double price}) {
    final tid = resolvedTableId;
    if (tid.isEmpty || name.trim().isEmpty || price <= 0) {
      return Future.value(false);
    }
    return _write(
      () => _apiService.createCartItem(
        tableId: tid,
        menuId: null,
        menuPrice: price,
        isExtraAddon: true,
        menuName: name.trim(),
        taxId: _consolidatedTax?['_id']?.toString(),
        taxName: _consolidatedTax?['name']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
        containerPrice: _containerPriceArg,
      ),
    );
  }

  static bool isKotLine(Map<String, dynamic> line) =>
      line['kot_status'] == 1 ||
      line['kot_status'] == '1' ||
      line['kotprint_status'] == 1 ||
      line['kotprint_status'] == '1';

  Map<String, dynamic>? _line(String cartmenuId) {
    for (final l in cartMenuItems) {
      if (l['_id']?.toString() == cartmenuId) return l;
    }
    return null;
  }

  /// Quantity change — refused on KOT'd lines (admin hard-locks them).
  Future<bool> updateItemQuantity(String cartmenuId, int newQty) async {
    final line = _line(cartmenuId);
    if (line != null && isKotLine(line)) {
      _errorMessage =
          'This item is already sent to the kitchen. Cancel it instead.';
      notifyListeners();
      return false;
    }
    if (newQty <= 0) return removeCartItem(cartmenuId);
    final cid = cartId;
    if (cid.isEmpty) return false;
    return _write(
      () => _apiService.updateCartItemQuantity(
        cartId: cid,
        cartmenuId: cartmenuId,
        quantity: newQty,
        taxId: _consolidatedTax?['_id']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
        containerPrice: _containerPriceArg,
      ),
    );
  }

  /// Remove an un-KOT'd line (hard delete). For a KOT'd line use [cancelKotLine].
  Future<bool> removeCartItem(String cartmenuId) async {
    final line = _line(cartmenuId);
    if (line != null && isKotLine(line)) {
      return cancelKotLine(cartmenuId, reason: 'Removed from order');
    }
    final cid = cartId;
    if (cid.isEmpty) return false;
    return _write(
      () => _apiService.deleteCartMenuItem(
        cartId: cid,
        cartmenuId: cartmenuId,
        taxId: _consolidatedTax?['_id']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
        containerPrice: _containerPriceArg,
      ),
    );
  }

  /// Cancel a KOT'd line with a reason (row kept, excluded from pricing).
  Future<bool> cancelKotLine(String cartmenuId, {required String reason}) {
    final cid = cartId;
    if (cid.isEmpty) return Future.value(false);
    return _write(
      () => _apiService.cancelCartMenuItem(
        cartId: cid,
        cartmenuId: cartmenuId,
        reason: reason.trim().isEmpty ? 'Removed from order' : reason.trim(),
        taxId: _consolidatedTax?['_id']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
        containerPrice: _containerPriceArg,
      ),
    );
  }

  // ============================================================
  // Print helpers
  // ============================================================

  /// Cart lines shaped for ESC/POS (from the live cart).
  List<CartLineItem> get printCartLines => _kotLinesFromMaps(cartMenuItems);

  DineInTable get _printTable =>
      _activeTable ??
      DineInTable(
        id: resolvedTableId,
        tableNumber: tableNumber.isEmpty ? resolvedTableId : tableNumber,
        areaId: _activeAreaId ?? '',
        noOfPeople: 0,
        tableStatus: tableStatus,
        status: '1',
        totalPrice: grandTotal,
        itemCount: totalItemCount,
      );

  /// Map viewmenu / cartmenu rows into ESC/POS cart lines.
  List<CartLineItem> _kotLinesFromMaps(List<Map<String, dynamic>> items) {
    return items.map((m) {
      final menu =
          m['menu'] ??
          (m['menuData'] is List && (m['menuData'] as List).isNotEmpty
              ? (m['menuData'] as List).first
              : null);
      final menuMap = menu is Map ? Map<String, dynamic>.from(menu) : null;
      final name =
          menuMap?['displayname']?.toString() ??
          menuMap?['name']?.toString() ??
          m['menu_name']?.toString() ??
          m['name']?.toString() ??
          'Item';
      final variant = m['variant'];
      final variantMap = variant is Map
          ? Map<String, dynamic>.from(variant)
          : (variant is List && variant.isNotEmpty && variant.first is Map
                ? Map<String, dynamic>.from(variant.first as Map)
                : null);
      final variantName =
          variantMap?['valuename']?.toString() ??
          variantMap?['name']?.toString() ??
          m['variant_name']?.toString();
      final addons = <MenuAddon>[];
      final addonRaw = m['addon'] ?? m['addonData'];
      if (addonRaw is List) {
        for (final a in addonRaw) {
          if (a is Map) {
            addons.add(MenuAddon.fromJson(Map<String, dynamic>.from(a)));
          }
        }
      }
      final unit = _num(m['individual_price'] ?? m['menu_price']);
      return CartLineItem(
        id: m['_id']?.toString() ?? '',
        item: MenuItem(
          id: m['menu_id']?.toString() ?? menuMap?['_id']?.toString() ?? '',
          categoryId: m['category_id']?.toString() ?? '',
          name: name,
          attribute: menuMap?['attribute']?.toString() ?? 'VEG',
          price: unit,
        ),
        quantity: int.tryParse(m['quantity']?.toString() ?? '1') ?? 1,
        selectedVariant: (variantName != null && variantName.isNotEmpty)
            ? MenuVariant(
                id:
                    variantMap?['_id']?.toString() ??
                    m['variant_id']?.toString() ??
                    '',
                name: variantName,
                price: unit,
              )
            : null,
        selectedAddons: addons,
        instruction: m['description']?.toString(),
        cancelStatus: (m['cancel_status'] == 1 || m['cancel_status'] == '1')
            ? 1
            : 0,
      );
    }).toList();
  }

  // ============================================================
  // KOT
  // ============================================================

  /// Send KOT via setcartstatus, then silent-print the un-printed lines
  /// (`viewmenu?status=kot`), then KOT_PRINT only after a successful print.
  /// Returns true when the KOT reached the kitchen; [printError] set if the
  /// print failed afterwards.
  Future<bool> sendKotOrder() async {
    final tid = resolvedTableId;
    final cid = cartId;
    if (tid.isEmpty || cid.isEmpty) {
      _errorMessage = 'No items on this table yet';
      notifyListeners();
      return false;
    }

    _isBusy = true;
    _errorMessage = null;
    printError = null;
    notifyListeners();

    try {
      // Un-printed lines BEFORE the status flip (KOT sets kot_status on all rows;
      // kotprint_status stays 0 until KOT_PRINT, so this is safe either way).
      List<CartLineItem> kotItems = [];
      try {
        final rows = await _apiService.getViewMenu(tableId: tid, status: 'kot');
        kotItems = _kotLinesFromMaps(rows);
      } on ApiException catch (e) {
        if (e.isAuth) rethrow;
        debugPrint(
          '[Fatfox POS] viewmenu kot failed, falling back to cart lines: $e',
        );
      }
      if (kotItems.isEmpty) {
        kotItems = _kotLinesFromMaps(
          cartMenuItems.where((i) => i['kotprint_status'] != 1).toList(),
        );
      }
      if (kotItems.isEmpty) kotItems = printCartLines;

      // 1) Fire only new lines. A printer retry must not create another KOT.
      if (hasUnsentKotItems) {
        await _apiService.sendKotToKitchen(cartId: cid);
        await _reloadCartData();
      }

      // 2) LAN print
      var printOk = false;
      try {
        final prefs = await ReceiptPrefs.load();
        final bytes = await _printer.generateKotBytes(
          table: _printTable,
          items: kotItems,
          restaurantName: prefs.header,
          paperSize: prefs.paperSize,
        );
        await _printer.printBytes(bytes);
        printOk = true;
      } catch (e) {
        printError = friendlyError(e);
        debugPrint('[Fatfox POS] KOT print error: $e');
      }

      // 3) KOT_PRINT only after a successful print
      if (printOk) {
        try {
          await _apiService.setCartStatus(
            cartId: cid,
            tableStatus: 'KOT_PRINT',
          );
          await _reloadCartData();
        } on ApiException catch (e) {
          if (e.isAuth) rethrow;
          debugPrint('[Fatfox POS] KOT_PRINT status failed: $e');
        }
      }

      _isBusy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      _sessionExpired = e.isAuth;
    } catch (e) {
      _errorMessage = friendlyError(e);
    }

    _isBusy = false;
    notifyListeners();
    return false;
  }

  // ============================================================
  // Discounts
  // ============================================================

  Future<List<Map<String, dynamic>>> listDiscounts({
    String searchName = '',
  }) async {
    final amount = subTotal > 0 ? subTotal : grandTotal;
    try {
      return await _apiService.listAvailableDiscounts(
        orderAmount: amount,
        searchName: searchName,
      );
    } on ApiException catch (e) {
      if (e.isAuth) {
        _sessionExpired = true;
        notifyListeners();
      }
      debugPrint('[Fatfox POS] listDiscounts refused: $e');
      return [];
    } catch (e) {
      debugPrint('[Fatfox POS] listDiscounts error: $e');
      return [];
    }
  }

  Future<bool> applyDiscount(String discountId) {
    final cid = cartId;
    if (cid.isEmpty || discountId.isEmpty) return Future.value(false);
    return _write(
      () => _apiService.setCartDiscount(cartId: cid, discountId: discountId),
    );
  }

  Future<bool> clearDiscount() {
    final cid = cartId;
    if (cid.isEmpty) return Future.value(false);
    return _write(() => _apiService.removeCartDiscount(cartId: cid));
  }

  // ============================================================
  // Bill + settle
  // ============================================================

  /// Print the customer bill and mark the table PRINTED (admin "KOT + Bill").
  /// Returns null on success, else the error text. Un-printed items are sent
  /// to the kitchen first so the bill never disagrees with the kitchen.
  Future<String?> printBill({String? paymentMode}) async {
    final tid = resolvedTableId;
    final cid = cartId;
    if (tid.isEmpty || cid.isEmpty) return 'No items on this table yet';

    _isBusy = true;
    _errorMessage = null;
    printError = null;
    notifyListeners();

    String? failure;
    try {
      if (hasUnprintedItems) {
        failure = hasUnsentKotItems
            ? 'Send and print KOT before printing the bill'
            : 'Print KOT before printing the bill';
      }
      if (failure == null) {
        final data = await BillBuilder(_apiService).build(
          tableId: tid,
          tableNumber: tableNumber,
          paymentMode: paymentMode,
          cartSnapshot: cart,
          taxRows: _taxConfig,
        );
        if (data == null) {
          failure = 'No active cart found for this table';
        } else {
          final prefs = await ReceiptPrefs.load();
          final bytes = await _printer.generateBillBytes(
            bill: data,
            paperSize: prefs.paperSize,
          );
          await _printer.printBytes(bytes);
          await _markPrintedWithRetry(cid);
          await _reloadCartData();
        }
      }
    } on ApiException catch (e) {
      failure = e.message;
      _sessionExpired = e.isAuth;
    } catch (e) {
      failure = friendlyError(e);
      printError = failure;
    }

    _isBusy = false;
    notifyListeners();
    return failure;
  }

  /// PRINTED is what unlocks Release — retry transport failures like admin.
  Future<void> _markPrintedWithRetry(String cid) async {
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _apiService.setCartStatus(cartId: cid, tableStatus: 'PRINTED');
        return;
      } on ApiException catch (e) {
        if (e.isAuth || !e.isNetwork) rethrow;
        last = e;
        await Future.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    if (last != null) throw last;
  }

  /// SETTLE: `setcarttobill { cartId, paymentType }` — creates the Order and
  /// deletes the cart. The caller must print the bill first.
  Future<bool> settleAndPrintBill({String paymentType = 'CASH'}) async {
    final cid = cartId;
    if (cid.isEmpty) {
      _errorMessage = 'No active cart for this table';
      notifyListeners();
      return false;
    }
    final mode = ApiService.normalizePaymentType(paymentType);

    if (!canRelease) {
      _errorMessage = releaseBlockedReason;
      notifyListeners();
      return false;
    }

    _isBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _apiService.settleBill(cartId: cid, paymentType: mode);
      _cartData = [];
      _isBusy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      // e.g. split_not_fully_paid / qr_order_awaiting_approval — show verbatim.
      _errorMessage = e.message;
      _sessionExpired = e.isAuth;
    } catch (e) {
      _errorMessage = friendlyError(e);
    }
    _isBusy = false;
    notifyListeners();
    return false;
  }

  void clearCart() {
    _cartData = [];
    notifyListeners();
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }
}
