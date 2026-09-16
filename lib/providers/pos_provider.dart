import 'package:flutter/foundation.dart';

import '../models/table_model.dart';
import '../models/menu_model.dart';
import '../models/cart_model.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/bill_builder.dart';
import '../services/menu_cache_service.dart';
import '../services/receipt_customization_service.dart';
import '../services/thermal_printer_service.dart';
import '../utils/extra_addons.dart';
import '../utils/menu_filter.dart';

/// Group of KOT items for one kitchen department ticket.
class KotGroup {
  final String name;
  final List<CartLineItem> items;

  KotGroup({required this.name, required this.items});
}

/// Ordering screen state for ONE open table. Mirrors the admin
/// `dinein-food-categories` contract:
/// * every cart write goes to the live backend and repaints from the response;
/// * `container_price` is echoed on every write (the server resets it to 0 otherwise);
/// * quantity is locked once a line is KOT'd — removal is `cancelmenu` with a reason;
/// * KOT = `setcartstatus KOT` → print → `KOT_PRINT` only after a successful print;
/// * Bill = print → `setcartstatus PRINTED`; Settle = `setcarttobill` (deletes the cart);
/// * Discard = `DELETE deletecart/{id}` (empties cart, no Order — admin Discard).
class PosProvider with ChangeNotifier {
  final ApiService _apiService;
  final ThermalPrinterService _printer;
  final MenuCacheService _menuCache;
  final AuthService _authService;
  final ReceiptCustomizationService _receiptCustomization;

  PosProvider({
    ApiService? api,
    ThermalPrinterService? printer,
    MenuCacheService? menuCache,
    AuthService? auth,
    ReceiptCustomizationService? receiptCustomization,
  })  : _apiService = api ?? ApiService(),
        _printer = printer ?? ThermalPrinterService(),
        _menuCache = menuCache ?? MenuCacheService(),
        _authService = auth ?? AuthService(),
        _receiptCustomization =
            receiptCustomization ?? ReceiptCustomizationService() {
    ThermalPrinterService.warmup();
  }

  // ── Table ──
  String? _activeTableId;
  String? _activeAreaId;
  Map<String, dynamic>? _tableDetails;
  DineInTable? _activeTable;

  // ── Menu ──
  List<MenuCategory> _categories = [];
  List<MenuItem> _allItems = [];
  String? _selectedCategoryId; // null = 'ALL'; favorites/extra = sentinels
  List<Map<String, dynamic>>? _extraAddonRawGroups; // null = not loaded / failed
  bool _extraAddonsLoading = false;
  /// variant_id → display name from GET /restaurant/variant/all (admin join).
  Map<String, String> _variantNameById = {};
  String _searchQuery = '';

  // ── Kitchen Departments (KOT stations) ──
  List<Map<String, dynamic>> _kitchenDepartments = [];
  Map<String, String> _deptNameMap = {};
  List<String> _deptOrder = [];

  // ── Cart (live backend snapshot) ──
  List<Map<String, dynamic>> _cartData = [];
  bool _floorDirty = false;
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
  Map<String, String> get variantNameById => _variantNameById;
  String? get selectedCategoryId => _selectedCategoryId;
  bool get isExtraAddonsLoading => _extraAddonsLoading;
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
  Map<String, String> get deptNameMap => _deptNameMap;
  List<String> get deptOrder => _deptOrder;
  List<Map<String, dynamic>> get kitchenDepartments => _kitchenDepartments;

  /// True when POS mutations should force a floor refresh on return.
  bool get floorDirty => _floorDirty;

  void markFloorDirty() => _floorDirty = true;

  /// Returns whether the floor needs refresh, then clears the flag.
  bool consumeFloorDirty() {
    final dirty = _floorDirty;
    _floorDirty = false;
    return dirty;
  }

  void clearFloorDirty() => _floorDirty = false;

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
    if (_selectedCategoryId == kFavoritesCategoryId) {
      final favs = _allItems.where((i) => i.isFavorite).toList();
      return filterMenuItems(
        items: favs,
        search: _searchQuery,
        alreadySorted: true,
      );
    }
    if (_selectedCategoryId == kExtraAddonsCategoryId) {
      final groups = _extraAddonRawGroups;
      if (groups == null) return const [];
      return mapExtraAddonCards(groups, search: _searchQuery);
    }

    MenuCategory? selected;
    if (_selectedCategoryId != null &&
        _selectedCategoryId!.isNotEmpty &&
        !isSpecialMenuMode(_selectedCategoryId)) {
      for (final c in _categories) {
        if (c.id == _selectedCategoryId) {
          selected = c;
          break;
        }
      }
    }

    // Admin dine-in: match by category name (by-category-itemin strips ids).
    // [_allItems] is kept sorted by label so filter skips re-sort.
    return filterMenuItems(
      items: _allItems,
      categoryNames: selected?.filterNames ?? const [],
      categoryId: selected?.id,
      search: _searchQuery,
      alreadySorted: true,
    );
  }

  bool get hasActiveFilters =>
      (_selectedCategoryId != null && _selectedCategoryId!.isNotEmpty) ||
      _searchQuery.trim().isNotEmpty;

  /// Menu ids currently in the live cart (for O(1) tile highlight).
  Set<String> get cartMenuIds {
    final out = <String>{};
    for (final ci in cartMenuItems) {
      final menuData = ci['menuData'];
      if (menuData is List && menuData.isNotEmpty) {
        final id = menuData[0]['_id']?.toString();
        if (id != null && id.isNotEmpty) out.add(id);
      }
    }
    return out;
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

  /// Phase 1 safety rule: Release only after the bill status is durable,
  /// unless device pref `kot_enable_release_table` matches admin exception.
  bool get canRelease {
    if (cartId.isEmpty || cartMenuItems.isEmpty) return false;
    if (hasUnsentKotItems || hasUnprintedItems) return false;
    final s = tableStatus;
    if (s == 'PRINTED' || s == 'PAID') return true;
    final allowKotRelease = _receiptPrefs?.kotEnableReleaseTable ?? false;
    if (!allowKotRelease) return false;
    return s == 'KOT_PRINT' || s == 'KOT' || s == 'RUNNING';
  }

  String get releaseBlockedReason {
    if (cartId.isEmpty || cartMenuItems.isEmpty) {
      return 'No items on this table';
    }
    if (hasUnsentKotItems) return 'Send KOT for the new items first';
    if (hasUnprintedItems) return 'Print KOT before printing the bill';
    final allowKotRelease = _receiptPrefs?.kotEnableReleaseTable ?? false;
    if (allowKotRelease) {
      return 'Send/print KOT before releasing the table';
    }
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
    if (_selectedCategoryId == categoryId) {
      // Retry Extra load if a prior attempt failed (cache left null).
      if (categoryId == kExtraAddonsCategoryId &&
          _extraAddonRawGroups == null &&
          !_extraAddonsLoading) {
        ensureExtraAddonsLoaded(force: true);
      }
      return;
    }
    _selectedCategoryId = categoryId;
    notifyListeners();
    if (categoryId == kExtraAddonsCategoryId) {
      ensureExtraAddonsLoaded();
    }
  }

  /// Load Extra Add-ons groups once (admin AllAvailableAddons).
  Future<void> ensureExtraAddonsLoaded({bool force = false}) async {
    if (_extraAddonsLoading) return;
    if (!force && _extraAddonRawGroups != null) return;
    _extraAddonsLoading = true;
    notifyListeners();
    try {
      _extraAddonRawGroups = await _apiService.getAllAvailableAddons();
      if (_errorMessage == 'Failed to load extra add-ons') {
        _errorMessage = null;
      }
    } catch (e) {
      debugPrint('[Fatfox POS] Extra add-ons load failed: $e');
      _extraAddonRawGroups = null; // allow retry on re-select
      _errorMessage = 'Failed to load extra add-ons';
    } finally {
      _extraAddonsLoading = false;
      notifyListeners();
    }
  }

  void setSearchQuery(String q) {
    if (_searchQuery == q) return;
    _searchQuery = q;
    notifyListeners();
  }

  /// Reset category + search (ALL menu, empty query).
  void clearFilters() {
    final had =
        _selectedCategoryId != null || _searchQuery.trim().isNotEmpty;
    _selectedCategoryId = null;
    _searchQuery = '';
    if (had) notifyListeners();
  }

  /// Admin loads full variant/addon values via `viewMenubyId` when customisable.
  /// getmenu returns `{ variant_id, price }` without names — join `_variantNameById`.
  Future<MenuItem?> enrichMenuItem(MenuItem item) async {
    if (item.id.isEmpty) return null;
    try {
      await _ensureVariantCatalog();
      final raw = await _apiService.getMenuById(item.id);
      if (raw == null) return null;
      final enriched = MenuItem.fromJson(raw);
      final variants = _joinVariantNames(
        enriched.variants.isNotEmpty ? enriched.variants : item.variants,
      );
      // Keep list-derived category names (detail doc may omit nested category).
      return MenuItem(
        id: enriched.id.isNotEmpty ? enriched.id : item.id,
        categoryId: enriched.categoryId.isNotEmpty
            ? enriched.categoryId
            : item.categoryId,
        categoryNames: enriched.categoryNames.isNotEmpty
            ? enriched.categoryNames
            : item.categoryNames,
        categoryIds: enriched.categoryIds.isNotEmpty
            ? enriched.categoryIds
            : item.categoryIds,
        name: enriched.name,
        displayName: enriched.displayName ?? item.displayName,
        shortCode: enriched.shortCode ?? item.shortCode,
        attribute: enriched.attribute,
        price: enriched.price > 0 ? enriched.price : item.price,
        image: enriched.image ?? item.image,
        variants: variants,
        addons: enriched.addons.isNotEmpty ? enriched.addons : item.addons,
        customisable: enriched.customisable || item.customisable,
        isFavorite: enriched.isFavorite || item.isFavorite,
      );
    } on ApiException catch (e) {
      if (e.isAuth) {
        _sessionExpired = true;
        _errorMessage = e.message;
        notifyListeners();
      }
      return null;
    } catch (e) {
      debugPrint('[Fatfox POS] enrichMenuItem failed: $e');
      return null;
    }
  }

  Future<void> _ensureVariantCatalog() async {
    if (_variantNameById.isNotEmpty) return;
    try {
      final rows = await _apiService.getAllVariants();
      final map = <String, String>{};
      for (final row in rows) {
        final id = (row['_id'] ?? row['id'] ?? row['variant_id'] ?? row['value_id'])?.toString() ?? '';
        if (id.isEmpty) continue;
        final name = (row['name'] ?? row['valuename'] ?? row['displayname'] ?? row['title'] ?? row['variant_name'] ?? row['value_name'])
                ?.toString()
                .trim() ??
            '';
        if (name.isNotEmpty) map[id] = name;
      }
      _variantNameById = map;
      if (_allItems.isNotEmpty && map.isNotEmpty) {
        _setSortedMenuItems(_allItems);
      }
    } catch (e) {
      debugPrint('[Fatfox POS] variant catalog load failed: $e');
    }
  }

  List<MenuVariant> _joinVariantNames(List<MenuVariant> variants) {
    if (variants.isEmpty) return variants;
    return [
      for (final v in variants)
        MenuVariant(
          id: v.id,
          name: (v.name.isNotEmpty && v.name.trim().toLowerCase() != 'variant')
              ? v.name
              : (_variantNameById[v.id] ?? (v.name.isNotEmpty ? v.name : '')),
          price: v.price,
        ),
    ];
  }

  void _setSortedMenuItems(List<MenuItem> items) {
    final sorted = List<MenuItem>.from(items);
    sorted.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    _allItems = [
      for (final item in sorted)
        if (item.variants.isNotEmpty)
          MenuItem(
            id: item.id,
            categoryId: item.categoryId,
            categoryNames: item.categoryNames,
            categoryIds: item.categoryIds,
            name: item.name,
            displayName: item.displayName,
            shortCode: item.shortCode,
            attribute: item.attribute,
            price: item.price,
            image: item.image,
            variants: _joinVariantNames(item.variants),
            addons: item.addons,
            customisable: item.customisable,
            isFavorite: item.isFavorite,
            isExtraAddon: item.isExtraAddon,
            isCustomAddonTrigger: item.isCustomAddonTrigger,
            departments: item.departments,
          )
        else
          item,
    ];
  }

  // ============================================================
  // Loading (admin ngOnInit chain)
  // ============================================================

  /// Load everything the ordering screen needs. Table + categories + menu are
  /// mandatory; tax config is best-effort; the cart is loaded last and its
  /// failure is reported separately so the menu still renders.
  ///
  /// Categories/menu paint from disk cache first (if any), then refresh from
  /// the network like admin's warm menu cache.
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
      final restaurantId = await _authService.getRestaurantId() ?? '';
      final cached = await _menuCache.load(restaurantId);
      if (cached != null &&
          (cached.categories.isNotEmpty || cached.items.isNotEmpty)) {
        _categories = cached.categories;
        _setSortedMenuItems(cached.items);
        // Let the grid paint while table + network refresh continue.
        notifyListeners();
      }

      final results = await Future.wait<Object?>([
        _apiService.viewTableById(tableId),
        _apiService.getActiveCategoryMaps(),
        _apiService.getDineinMenuMaps(),
        _bestEffortTax(),
        _bestEffortVariantCatalog(),
        _bestEffortKitchenDepartments(),
      ]);
      _tableDetails = results[0] as Map<String, dynamic>?;
      final catMaps = results[1] as List<Map<String, dynamic>>;
      final itemMaps = results[2] as List<Map<String, dynamic>>;
      _categories = catMaps.map(MenuCategory.fromJson).toList();
      _setSortedMenuItems(itemMaps.map(MenuItem.fromJson).toList());
      _taxConfig = results[3] as List<Map<String, dynamic>>;
      _buildConsolidatedTax();
      final variantMaps = results[4] as List<Map<String, dynamic>>;
      if (variantMaps.isNotEmpty) {
        final map = <String, String>{};
        for (final row in variantMaps) {
          final id = row['_id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final name =
              (row['name'] ?? row['valuename'] ?? row['displayname'])
                      ?.toString()
                      .trim() ??
                  '';
          if (name.isNotEmpty) map[id] = name;
        }
        if (map.isNotEmpty) _variantNameById = map;
      }
      final deptMaps = results[5] as List<Map<String, dynamic>>;
      if (deptMaps.isNotEmpty) {
        populateKitchenDepartments(deptMaps);
      }

      await _menuCache.save(
        restaurantId: restaurantId,
        categories: catMaps,
        items: itemMaps,
      );

      if (_tableDetails == null ||
          (_tableDetails!['table_id'] ?? _tableDetails!['_id']) == null) {
        _errorMessage = 'This table no longer exists. Go back to the floor.';
      } else {
        debugPrint(
          '[Fatfox POS] Loaded table ${_tableDetails?['table_number']}: '
          '${_categories.length} categories, ${_allItems.length} items, '
          '${_taxConfig.length} tax rows, ${_kitchenDepartments.length} kitchen departments',
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

  Future<List<Map<String, dynamic>>> _bestEffortVariantCatalog() async {
    try {
      return await _apiService.getAllVariants();
    } on ApiException catch (e) {
      if (e.isAuth) rethrow;
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _bestEffortKitchenDepartments() async {
    try {
      return await _apiService.getKitchenDepartments();
    } on ApiException catch (e) {
      if (e.isAuth) rethrow;
      return const [];
    } catch (_) {
      return const [];
    }
  }

  void populateKitchenDepartments(List<Map<String, dynamic>> rawList) {
    _kitchenDepartments = rawList;
    final sorted = List<Map<String, dynamic>>.from(rawList);
    sorted.sort((a, b) {
      final ordA = num.tryParse(a['sort_order']?.toString() ?? '0') ?? 0;
      final ordB = num.tryParse(b['sort_order']?.toString() ?? '0') ?? 0;
      return ordA.compareTo(ordB);
    });
    _deptOrder = sorted
        .map((d) => (d['name'] ?? d['valuename'] ?? d['department_name'] ?? d['displayname'])?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    _deptNameMap = {};
    for (final d in rawList) {
      final id = (d['_id'] ?? d['id'])?.toString() ?? '';
      final name = (d['name'] ?? d['valuename'] ?? d['department_name'] ?? d['displayname'])?.toString() ?? '';
      if (id.isNotEmpty && name.isNotEmpty) {
        _deptNameMap[id] = name;
      }
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
  /// otherwise refetches. Empty success (last-line delete) clears locally —
  /// no listallcartmenus follow-up.
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
      // Last-line deletemenu returns [] — cart is already gone server-side.
      _cartData = [];
      _cartError = null;
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
      markFloorDirty();
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
    final cid = cartId;
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
        cartId: cid,
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
    final cid = cartId;
    if (tid.isEmpty || name.trim().isEmpty || price <= 0) {
      _errorMessage = tid.isEmpty
          ? 'Table not loaded'
          : 'Enter a valid name and amount';
      notifyListeners();
      return Future.value(false);
    }
    return _write(
      () => _apiService.createCartItem(
        tableId: tid,
        cartId: cid,
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
          categoryId: m['category_id']?.toString() ?? menuMap?['category_id']?.toString() ?? '',
          name: name,
          attribute: menuMap?['attribute']?.toString() ?? 'VEG',
          price: unit,
          departments: parseDepartments(
            m['departments'] ??
                menuMap?['departments'] ??
                (m['category'] is Map ? m['category']['departments'] : null),
          ),
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

  /// Resolves kitchen department names for a line item.
  List<String> getDeptNamesForLine(CartLineItem line) {
    final ids = <String>[];

    // 1. From line.item.departments (carried from menuMap or raw cart row)
    for (final d in line.item.departments) {
      if (d.isNotEmpty && !ids.contains(d)) ids.add(d);
    }

    // 2. Fall back to category lookup in _categories
    if (ids.isEmpty && line.item.categoryId.isNotEmpty) {
      for (final cat in _categories) {
        if (cat.id == line.item.categoryId) {
          for (final d in cat.departments) {
            if (d.isNotEmpty && !ids.contains(d)) ids.add(d);
          }
          break;
        }
      }
    }

    // 3. Fall back to looking up line.item.id or line.item.name in _allItems
    if (ids.isEmpty) {
      final targetId = line.item.id.trim();
      final targetName = line.item.name.trim().toLowerCase();
      for (final it in _allItems) {
        final matchId = targetId.isNotEmpty && it.id.trim() == targetId;
        final matchName = targetName.isNotEmpty && it.name.trim().toLowerCase() == targetName;
        if (matchId || matchName) {
          for (final d in it.departments) {
            if (d.isNotEmpty && !ids.contains(d)) ids.add(d);
          }
          if (ids.isEmpty && it.categoryId.isNotEmpty) {
            for (final cat in _categories) {
              if (cat.id == it.categoryId) {
                for (final d in cat.departments) {
                  if (d.isNotEmpty && !ids.contains(d)) ids.add(d);
                }
                break;
              }
            }
          }
          if (ids.isEmpty) {
            for (final catId in it.categoryIds) {
              for (final cat in _categories) {
                if (cat.id == catId) {
                  for (final d in cat.departments) {
                    if (d.isNotEmpty && !ids.contains(d)) ids.add(d);
                  }
                }
              }
            }
          }
          if (ids.isNotEmpty) break;
        }
      }
    }

    // Convert IDs -> Names using _deptNameMap
    final names = <String>[];
    for (final id in ids) {
      final name = _deptNameMap[id] ?? id;
      if (name.isNotEmpty && !names.contains(name)) {
        names.add(name);
      }
    }

    return names;
  }

  /// Group KOT lines by department for individual department tickets (autocut between stations).
  /// Multi-department lines repeat on each linked department ticket; unassigned lines fall into "General".
  List<KotGroup> buildKotGroups(List<CartLineItem> items) {
    final groups = <String, List<CartLineItem>>{};

    for (final item in items) {
      final names = getDeptNamesForLine(item);
      if (names.isEmpty) {
        groups.putIfAbsent('General', () => []).add(item);
      } else {
        for (final name in names) {
          groups.putIfAbsent(name, () => []).add(item);
        }
      }
    }

    int sortKey(String name) {
      if (name == 'General') return 1000000000;
      final idx = _deptOrder.indexOf(name);
      return idx == -1 ? 100000000 : idx;
    }

    final keys = groups.keys.toList()
      ..sort((a, b) {
        final keyA = sortKey(a);
        final keyB = sortKey(b);
        if (keyA != keyB) return keyA.compareTo(keyB);
        return a.compareTo(b);
      });

    return keys.map((k) => KotGroup(name: k, items: groups[k]!)).toList();
  }

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
      // 1) Gather items from local state first to avoid network latency before print
      List<CartLineItem> kotItems = _kotLinesFromMaps(
        cartMenuItems
            .where((i) =>
                i['kotprint_status'] != 1 && i['kotprint_status'] != '1')
            .toList(),
      );
      if (kotItems.isEmpty) kotItems = printCartLines;

      // 2) Send unsent lines to kitchen backend if any
      if (hasUnsentKotItems) {
        await _apiService.sendKotToKitchen(cartId: cid);
      }

      // 3) Silent print KOT tickets (one per kitchen department, with ESC/POS autocut)
      try {
        final prefs = await ReceiptPrefs.load();
        final customization = await _receiptCustomization.loadCached();
        final groups = buildKotGroups(kotItems);
        debugPrint('[Fatfox POS] KOT Print: ${kotItems.length} items divided into ${groups.length} department ticket(s):');
        for (final g in groups) {
          debugPrint('  - Station/Dept: "${g.name}", Items: ${g.items.map((i) => i.item.name).join(', ')}');
        }
        for (var i = 0; i < groups.length; i++) {
          final group = groups[i];
          final bytes = await _printer.generateKotBytes(
            table: _printTable,
            items: group.items,
            restaurantName: prefs.header,
            paperSize: prefs.paperSize,
            department: group.name,
            customization: customization,
          );
          await _printer.printBytes(bytes, role: PrinterRole.kot);
          if (i < groups.length - 1) {
            await Future.delayed(const Duration(milliseconds: 150));
          }
        }
      } catch (e) {
        printError = friendlyError(e);
        debugPrint('[Fatfox POS] KOT thermal print error: $e');
      }

      // 4) Update status on backend to KOT_PRINT so order advances on server & table status updates
      try {
        await _apiService.setCartStatus(
          cartId: cid,
          tableStatus: 'KOT_PRINT',
        );
      } on ApiException catch (e) {
        if (e.isAuth) rethrow;
        debugPrint('[Fatfox POS] KOT_PRINT status failed: $e');
      }

      await _reloadCartData();

      _isBusy = false;
      notifyListeners();
      markFloorDirty();
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

  /// Floor print: bind table cart temporarily, print, then restore prior POS bind
  /// so an open food-categories screen is not left on the wrong table.
  Future<String?> printBillForFloorTable({
    required String tableId,
    required String areaId,
  }) async {
    final prevTableId = _activeTableId;
    final prevAreaId = _activeAreaId;
    final prevCart = List<Map<String, dynamic>>.from(_cartData);
    final prevDetails = _tableDetails;
    final prevTax = List<Map<String, dynamic>>.from(_taxConfig);
    final prevConsolidated = _consolidatedTax;
    try {
      final prep = await prepareTableForBill(tableId: tableId, areaId: areaId);
      if (prep != null) return prep;
      return await printBill();
    } finally {
      _activeTableId = prevTableId;
      _activeAreaId = prevAreaId;
      _cartData = prevCart;
      _tableDetails = prevDetails;
      _taxConfig = prevTax;
      _consolidatedTax = prevConsolidated;
      notifyListeners();
    }
  }

  /// Lightweight floor bind: table header + cart (+ tax) so [printBill] works
  /// without loading the full menu (admin floor print path).
  Future<String?> prepareTableForBill({
    required String tableId,
    required String areaId,
  }) async {
    _activeTableId = tableId;
    _activeAreaId = areaId;
    try {
      final results = await Future.wait<Object?>([
        _apiService.viewTableById(tableId),
        _apiService.getCartItemsByTableId(tableId),
        _bestEffortTax(),
      ]);
      _tableDetails = results[0] as Map<String, dynamic>?;
      _cartData = results[1] as List<Map<String, dynamic>>;
      _taxConfig = results[2] as List<Map<String, dynamic>>;
      _buildConsolidatedTax();
      notifyListeners();
      if (cartId.isEmpty) return 'No items on this table yet';
      return null;
    } on ApiException catch (e) {
      _sessionExpired = e.isAuth;
      return e.message;
    } catch (e) {
      return friendlyError(e);
    }
  }

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
      if (hasUnsentKotItems) {
        failure = 'Send KOT to kitchen before printing the bill';
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
          final customization = await _receiptCustomization.loadCached();
          try {
            final bytes = await _printer.generateBillBytes(
              bill: data,
              paperSize: prefs.paperSize,
              customization: customization,
            );
            await _printer.printBytes(bytes, role: PrinterRole.bill);
          } catch (e) {
            printError = friendlyError(e);
            debugPrint('[Fatfox POS] Bill thermal print error: $e');
            failure = 'Printer error: ${friendlyError(e)}';
          }
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
    if (failure == null || printError != null) markFloorDirty();
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

  /// Admin Discard: delete the whole cart without creating an Order/ledger.
  /// Confirmed in the UI before calling. Does not settle payment.
  Future<bool> discardCart() async {
    final cid = cartId;
    if (cid.isEmpty) {
      _cartData = [];
      _errorMessage = null;
      notifyListeners();
      return true;
    }

    _isBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _apiService.deleteCart(cid);
      _cartData = [];
      markFloorDirty();
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
      markFloorDirty();
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
