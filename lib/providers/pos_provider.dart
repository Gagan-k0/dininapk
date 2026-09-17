import 'package:flutter/foundation.dart';

import '../models/table_model.dart';
import '../models/menu_model.dart';
import '../models/cart_model.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/bill_builder.dart';
import '../services/connectivity_service.dart';
import '../services/device_id_service.dart';
import '../services/draft_cart_store.dart';
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
  final DraftCartStore _drafts;

  PosProvider({
    ApiService? api,
    ThermalPrinterService? printer,
    MenuCacheService? menuCache,
    AuthService? auth,
    ReceiptCustomizationService? receiptCustomization,
    DraftCartStore? drafts,
  })  : _drafts = drafts ?? DraftCartStore(),
        _apiService = api ?? ApiService(),
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

  // ── Draft (items added on this tablet, not sent yet) ──
  TableDraft? _draft;
  String _restaurantId = '';
  /// Tables with a send in flight. Per table, so a background send for one
  /// table never blocks the waiter on another.
  final Set<String> _sending = {};
  bool get _openTableSending => _sending.contains(resolvedTableId);
  bool _sendingAll = false;
  /// A send in this loop was refused as signed out or subscription-locked
  /// (background calls never log out or lock, so the loop stops by itself).
  bool _stopSendAll = false;
  bool _sendAllAgain = false;

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

  /// Unsent items for the open table, or null.
  TableDraft? get draft => _openDraft;

  /// The in-memory draft only while its own table is the one in view; a floor
  /// bill for another table must never see it.
  TableDraft? get _openDraft =>
      _draft != null && _draft!.tableId == resolvedTableId ? _draft : null;
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
  /// Server lines, then this tablet's unsent draft lines (`is_draft: true`).
  List<Map<String, dynamic>> get cartMenuItems => [
    ..._serverLines,
    ...?_openDraft?.allLines.map((l) => l.toCartLineMap()),
  ];

  List<Map<String, dynamic>> get _serverLines {
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

  double get subTotal => _serverSubTotal + (_openDraft?.subtotal ?? 0);

  double get _serverSubTotal => _num(cart?['food_subtotal']) > 0
      ? _num(cart?['food_subtotal'])
      : _num(cart?['menu_total']);
  double get taxAmount => _num(cart?['tax_price']) + _draftTax;

  /// Estimate for unsent lines until the server prices them at KOT: added
  /// percentage taxes only. BACKWARD taxes are already inside the price;
  /// compounding (CALC_ON_TAX) and area surcharges are left to the server.
  double get _draftTax {
    final sub = _openDraft?.subtotal ?? 0;
    if (sub <= 0) return 0;
    var pct = 0.0;
    for (final t in _taxConfig) {
      final taxType = t['tax_type']?.toString().toUpperCase() ?? '';
      if (taxType == 'CALC_ON_TAX') return 0;
      if (taxType == 'BACKWARD') continue;
      if (t['value_type']?.toString().toUpperCase() != 'PERCENTAGE') continue;
      pct += _num(t['value_amount']);
    }
    return sub * pct / 100;
  }
  double get discountAmount => _num(cart?['discount_price']);
  String? get discountName => cart?['discount_name']?.toString();
  double get containerCharge => _num(cart?['container_price']);
  double get areaCharge => _num(cart?['area_charge']);
  double get roundOff => _num(cart?['round_off']);
  double get grandTotal =>
      _num(cart?['total_price']) + (_openDraft?.subtotal ?? 0) + _draftTax;

  int get totalItemCount => cartMenuItems.fold(
    0,
    (sum, item) =>
        sum + (int.tryParse(item['quantity']?.toString() ?? '1') ?? 1),
  );

  String get cartId => cart?['_id']?.toString() ?? '';

  /// Phase 1 safety rule: Release only after the bill status is durable,
  /// unless device pref `kot_enable_release_table` matches admin exception.
  bool get canRelease {
    if (_cartStale) return false;
    if (cartId.isEmpty || cartMenuItems.isEmpty) return false;
    if (hasUnsentKotItems || hasUnprintedItems) return false;
    final s = tableStatus;
    if (s == 'PRINTED' || s == 'PAID') return true;
    final allowKotRelease = _receiptPrefs?.kotEnableReleaseTable ?? false;
    if (!allowKotRelease) return false;
    return s == 'KOT_PRINT' || s == 'KOT' || s == 'RUNNING';
  }

  String get releaseBlockedReason {
    if (_cartStale) return _staleMessage;
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
    _draft = null;
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
    // Offline the list copy is all there is; don't wait out a timeout.
    if (item.id.isEmpty || !ConnectivityService.instance.isOnline) return null;
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
      final map = variantNamesFrom(rows);
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
          name: (v.name.isNotEmpty &&
                  v.name.trim().toLowerCase() != 'variant' &&
                  v.name.trim().toLowerCase() != 'option')
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
  Future<void> loadTableAndMenu(
    String tableId,
    String areaId, {
    bool forceMenuRefresh = false,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    _cartError = null;
    _sessionExpired = false;
    _activeTableId = tableId;
    _activeAreaId = areaId;
    // Nothing from the previously open table may survive into this one.
    if (_activeTable?.id != tableId) _activeTable = null;
    _tableDetails = null;
    _cartData = [];
    _draft = null;
    _cartStale = false;
    notifyListeners();

    CachedMenuSnapshot? cached;
    try {
      _receiptPrefs = await ReceiptPrefs.load();
      final restaurantId = await _authService.getRestaurantId() ?? '';
      _restaurantId = restaurantId;
      _draft = await _drafts.load(restaurantId, tableId);
      cached = await _menuCache.load(restaurantId);
      if (!ConnectivityService.instance.isOnline &&
          await _openOffline(tableId, cached)) {
        _isLoading = false;
        notifyListeners();
        return;
      }
      if (cached != null && cached.hasCatalog) {
        _categories = cached.categories;
        _setSortedMenuItems(cached.items);
        _menuCachedAt = cached.savedAt;
        // Let the grid paint while table + network refresh continue.
        notifyListeners();
      }

      // A fresh snapshot makes 5 of the 7 opening requests pointless — the
      // catalog barely changes during a shift, and re-downloading the whole
      // dine-in menu per table open is what made opening a table feel slow.
      // "Sync menu" (forceMenuRefresh) is the waiter's override.
      if (cached != null && cached.isSkippable && cached.isFresh && !forceMenuRefresh) {
        _applyCatalogExtras(
          taxRows: cached.taxRows,
          variantMaps: cached.variants,
          deptMaps: cached.departments,
        );
        // Items were sorted before the variant names existed; redo it now or
        // every variant item keeps a blank label for the whole session.
        _setSortedMenuItems(_allItems);
        _tableDetails = await _apiService.viewTableById(tableId);
      } else {
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
        final taxRows = results[3] as List<Map<String, dynamic>>;
        final variantMaps = results[4] as List<Map<String, dynamic>>;
        final deptMaps = results[5] as List<Map<String, dynamic>>;
        _applyCatalogExtras(
          taxRows: taxRows,
          variantMaps: variantMaps,
          deptMaps: deptMaps,
        );

        await _menuCache.save(
          restaurantId: restaurantId,
          categories: catMaps,
          items: itemMaps,
          taxRows: taxRows,
          variants: variantMaps,
          departments: deptMaps,
        );
        _menuCachedAt = DateTime.now();
      }

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
      if (!(e.isNetwork && await _openOffline(tableId, cached))) {
        _errorMessage = e.message;
      }
      _sessionExpired = e.isAuth;
    } catch (e) {
      debugPrint('[Fatfox POS] Load error: $e');
      _errorMessage = friendlyError(e);
    }

    _isLoading = false;
    notifyListeners();
  }

  /// No server: open the table from the cached menu and the last cart this
  /// tablet saw, so the waiter can keep adding items. False when there is no
  /// cached menu to show.
  Future<bool> _openOffline(String tableId, CachedMenuSnapshot? cached) async {
    if (cached == null || !cached.hasCatalog) return false;
    // A cold start has nothing in memory yet.
    _categories = cached.categories;
    _allItems = cached.items;
    _menuCachedAt = cached.savedAt;
    _applyCatalogExtras(
      taxRows: cached.taxRows,
      variantMaps: cached.variants,
      deptMaps: cached.departments,
    );
    _setSortedMenuItems(_allItems);
    final snap = await _drafts.loadSnapshot(_restaurantId, tableId);
    _tableDetails = snap?.table ?? {'table_id': tableId};
    _cartData = snap?.cart ?? [];
    _cartError = null;
    // A copy from the tablet: KOT and bill must re-read the server first.
    _cartStale = true;
    return true;
  }

  Future<void> _saveSnapshot() => _drafts.saveSnapshot(
    _restaurantId,
    resolvedTableId,
    table: _tableDetails,
    cart: _cartData,
  );

  /// When the catalog was last downloaded — drives "Menu updated Xh ago".
  DateTime? _menuCachedAt;
  DateTime? get menuCachedAt => _menuCachedAt;

  /// Tax rows, variant names and kitchen departments — applied the same way
  /// whether they came from the network or the disk snapshot.
  void _applyCatalogExtras({
    required List<Map<String, dynamic>> taxRows,
    required List<Map<String, dynamic>> variantMaps,
    required List<Map<String, dynamic>> deptMaps,
  }) {
    _taxConfig = taxRows;
    _buildConsolidatedTax();
    final map = variantNamesFrom(variantMaps);
    if (map.isNotEmpty) _variantNameById = map;
    if (deptMaps.isNotEmpty) {
      populateKitchenDepartments(deptMaps);
    }
  }

  /// id → display name over every field spelling the API has used for variants.
  static Map<String, String> variantNamesFrom(List<Map<String, dynamic>> rows) {
    final map = <String, String>{};
    for (final row in rows) {
      final id =
          (row['_id'] ?? row['id'] ?? row['variant_id'] ?? row['value_id'])
                  ?.toString() ??
              '';
      if (id.isEmpty) continue;
      final name = (row['name'] ??
                  row['valuename'] ??
                  row['displayname'] ??
                  row['title'] ??
                  row['variant_name'] ??
                  row['value_name'])
              ?.toString()
              .trim() ??
          '';
      if (name.isNotEmpty) map[id] = name;
    }
    return map;
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
      _cartStale = false;
      await _saveSnapshot();
      debugPrint(
        '[Fatfox POS] Cart: ${cartMenuItems.length} lines, total ₹$grandTotal, '
        'status $tableStatus',
      );
    } on ApiException catch (e) {
      _sessionExpired = e.isAuth;
      final snap = e.isNetwork && _cartData.isEmpty
          ? await _drafts.loadSnapshot(_restaurantId, tid)
          : null;
      if (snap != null) {
        _cartData = snap.cart;
        _cartStale = true;
      } else {
        _cartError = e.message;
      }
      debugPrint('[Fatfox POS] Cart reload refused: $e');
    } catch (e) {
      _cartError = friendlyError(e);
      debugPrint('[Fatfox POS] Cart reload error: $e');
    }
  }

  /// Re-reads [tid]'s cart and fails loudly (unlike [_reloadCartData]).
  Future<bool> _refreshCart(String tid) async {
    try {
      final carts = await _apiService.getCartItemsByTableId(tid, fresh: true);
      if (!_isOpen(tid)) return false;
      _cartData = carts;
      _cartError = null;
      _cartStale = false;
      await _saveSnapshot();
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      _sessionExpired = e.isAuth;
      return false;
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
      await _saveSnapshot();
      return;
    }
    if (env.data == null || list.isEmpty) {
      // Last-line deletemenu returns [] — cart is already gone server-side.
      _cartData = [];
      _cartError = null;
      await _saveSnapshot();
      return;
    }
    await _reloadCartData();
  }

  String get _containerPriceArg =>
      containerCharge > 0 ? containerCharge.toString() : '0';

  /// True when the last [_write] never reached the server.
  bool _lastWriteOffline = false;

  /// Leading-edge mutex for cart writes. Returns `null` if a write is already
  /// in flight (silent skip — callers must not toast that as failure).
  Future<bool?> _write(Future<ApiEnvelope> Function() call) async {
    if (_isBusy) return null;
    // An in-flight send repaints the cart when it lands and would overwrite
    // this write's result (or re-save a quantity read before it).
    if (_refuseWhileSending(resolvedTableId)) return false;
    _isBusy = true;
    _errorMessage = null;
    _lastWriteOffline = false;
    notifyListeners();
    try {
      final env = await call();
      await _paintFromWrite(env);
      markFloorDirty();
      _isBusy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.isTableClaimed ? e.claimMessage : e.message;
      _sessionExpired = e.isAuth;
      _lastWriteOffline = e.isNetwork;
    } catch (e) {
      _errorMessage = friendlyError(e);
    }
    _isBusy = false;
    notifyListeners();
    return false;
  }

  /// Taps land on the tablet and are sent in one request at KOT. The one
  /// exception is the first item on a table with no cart while online: the
  /// server only accepts a batch into an existing cart, so that item opens it.
  Future<bool?> _addLine(
    DraftLine line,
    Future<ApiEnvelope> Function() openCart,
  ) async {
    if (_openDraft == null &&
        cartId.isEmpty &&
        ConnectivityService.instance.isOnline) {
      final wrote = await _write(openCart);
      if (wrote == null) return null; // another action in flight
      if (wrote) return true;
      if (!_lastWriteOffline) return false;
      // No answer: the cart may exist now. Keep the item, but locked, so KOT
      // checks the live cart before sending it again.
      return _addToDraft(line, maybeSent: true);
    }
    return _addToDraft(line);
  }

  bool _isOpen(String tableId) => resolvedTableId == tableId;

  Future<bool> _addToDraft(DraftLine line, {bool maybeSent = false}) async {
    final tid = resolvedTableId;
    if (tid.isEmpty || _restaurantId.isEmpty) {
      _errorMessage = 'Table not loaded';
      notifyListeners();
      return false;
    }
    if (_refuseWhileSending(tid)) return false;
    final current = _draft?.tableId == tid ? _draft : null;
    final base = current ?? TableDraft.start(_restaurantId, tid, cartId);
    _draft = maybeSent && base.isEmpty
        ? base.copyWith(creatingLine: line)
        : base.add(line);
    _errorMessage = null;
    notifyListeners();
    await _drafts.save(_draft!);
    return true;
  }

  /// Unsent items older than this on a table with no order wait for the
  /// waiter instead of opening a new order in the background.
  static const Duration _staleDraftAge = Duration(hours: 6);
  static const String _staleDraftMessage =
      'These items waited over 6 hours on an empty table. Check before sending.';

  static const String _sendingMessage =
      'Sending to the server — try again in a moment.';

  /// True (with the message shown) while [tid]'s unsent items are being sent.
  bool _refuseWhileSending(String tid) {
    if (!_sending.contains(tid)) return false;
    _errorMessage = _sendingMessage;
    notifyListeners();
    return true;
  }

  static String _newLineId() => DeviceIdService.randomHex().substring(0, 12);

  /// Persists [d]; it becomes the painted draft only if its table is still open.
  Future<void> _saveDraft(TableDraft d) async {
    if (_isOpen(d.tableId)) _draft = d.isEmpty ? null : d;
    await _drafts.save(d);
  }

  /// Add a menu item (admin `addItem` → createcart). The server merges into a
  /// matching un-KOT'd line, so re-adding a KOT'd item creates a NEW line for
  /// the next KOT — exactly as admin does.
  Future<bool?> addItemToCart(
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
    final line = DraftLine(
      lineId: _newLineId(),
      menuId: item.id,
      name: item.displayName ?? item.name,
      variantId: variantId,
      variantName: selectedVariant?.name,
      addons: addons ?? const [],
      quantity: quantity,
      unitPrice: menuPrice,
      description: description ?? '',
    );

    return _addLine(
      line,
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
  Future<bool?> addExtraItem({required String name, required double price}) {
    final tid = resolvedTableId;
    final cid = cartId;
    if (tid.isEmpty || name.trim().isEmpty || price <= 0) {
      _errorMessage = tid.isEmpty
          ? 'Table not loaded'
          : 'Enter a valid name and amount';
      notifyListeners();
      return Future.value(false);
    }
    final line = DraftLine(
      lineId: _newLineId(),
      menuId: null,
      name: name.trim(),
      quantity: 1,
      unitPrice: price,
      isExtra: true,
    );
    return _addLine(
      line,
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
  Future<bool?> updateItemQuantity(String cartmenuId, int newQty) async {
    if (_isDraftLine(cartmenuId)) return _setDraftQty(cartmenuId, newQty);
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
  Future<bool?> removeCartItem(String cartmenuId) async {
    if (_isDraftLine(cartmenuId)) return _setDraftQty(cartmenuId, 0);
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

  static bool _isDraftLine(String id) => id.startsWith(TableDraft.lineIdPrefix);

  Future<bool> _setDraftQty(String cartmenuId, int qty) async {
    final d = _openDraft;
    if (d == null) return false;
    final lineId = cartmenuId.substring(TableDraft.lineIdPrefix.length);
    final locked = d.creatingLine?.lineId == lineId && !d.conflict;
    if (_openTableSending || locked) {
      _errorMessage = locked
          ? 'This item may already be on the order. Send the KOT, then cancel it if needed.'
          : _sendingMessage;
      notifyListeners();
      return false;
    }
    _errorMessage = null;
    final edited = d.creatingLine?.lineId == lineId
        ? (qty > 0
              ? d.copyWith(creatingLine: d.creatingLine!.withQuantity(qty))
              : d.copyWith(clearCreating: true))
        : d.setQuantity(lineId, qty);
    final save = _saveDraft(edited);
    notifyListeners();
    await save;
    return true;
  }

  /// Set when items reached the server but the cart on screen could not be
  /// re-read; the next KOT must fetch before trusting it.
  bool _cartStale = false;
  static const String _staleMessage =
      'Items were sent but the order could not be refreshed. Try again.';

  /// Sends the open table's unsent items: one `offline-sync` request (plus one
  /// `createcart` if the table has no cart yet). True when nothing is left.
  ///
  /// Never adds items to a different order than the one they were taken for:
  /// if the table's cart changed meanwhile, the draft is flagged
  /// [TableDraft.conflict] and waits for the waiter. Pinned to the draft's own
  /// table, so leaving the screen mid-send cannot touch another table.
  Future<bool> flushDraft() async {
    final current = _openDraft;
    if (current == null) return true;
    return _flush(current, background: false);
  }

  /// Sends every table's unsent items (Sync on, back online, leaving a table).
  /// Parked drafts wait for the waiter. Returns how many tables were sent.
  /// Never writes the open screen's error text.
  Future<int> flushAllDrafts() async {
    // Always the signed-in restaurant: after a logout the provider may still
    // hold the previous restaurant's id and tax.
    final rid = await _authService.getRestaurantId() ?? '';
    if (rid.isEmpty) return 0;
    if (rid != _restaurantId) {
      _restaurantId = rid;
      _taxConfig = [];
      _consolidatedTax = null;
      _draft = null;
    }
    final tables = (await _drafts.all(rid)).map((d) => d.tableId).toList();
    DraftCartStore.pendingTables.value = tables.length;
    if (!ConnectivityService.instance.isOnline) return 0;
    if (_sendingAll) {
      _sendAllAgain = true; // e.g. back online while a loop is running
      return 0;
    }
    // Tax is restaurant-wide; without it a send would price the cart untaxed.
    // (Cached empty tax rows can mean a failed fetch, not "no tax", so a
    // no-tax restaurant's items wait for KOT, which sends them in the foreground.)
    if (_consolidatedTax == null) {
      final cached = await _menuCache.load(rid);
      if (cached != null && cached.taxRows.isNotEmpty) {
        _taxConfig = cached.taxRows;
        _buildConsolidatedTax();
      }
    }
    if (_consolidatedTax == null) return 0;

    _sendingAll = true;
    _stopSendAll = false;
    var sent = 0;
    try {
      for (final tid in tables) {
        // Re-read right before sending: the waiter may have added, sent,
        // parked or discarded this table's items since the loop started.
        final open = _draft;
        final d = open != null && open.tableId == tid
            ? open
            : await _drafts.load(rid, tid);
        if (d == null || d.conflict || _sending.contains(tid)) continue;
        // An edit on the open table is in flight; its reprice could re-save
        // a quantity read before that edit. The next pass sends it.
        if (_isBusy && _isOpen(tid)) continue;
        // (A locked creatingLine may have opened the order — _flush checks.)
        if (d.baselineCartId == null &&
            d.creatingLine == null &&
            DateTime.now().difference(d.createdAt) > _staleDraftAge) {
          // Days-old items must not silently open a new order on this table.
          await _saveDraft(d.copyWith(conflict: true, lastError: _staleDraftMessage));
          continue;
        }
        if (await _flush(d, background: true)) sent++;
        if (_stopSendAll || !ConnectivityService.instance.isOnline) break;
      }
    } finally {
      _sendingAll = false;
    }
    notifyListeners();
    if (_sendAllAgain) {
      _sendAllAgain = false;
      sent += await flushAllDrafts();
    }
    return sent;
  }

  /// "Send to current order" on a parked draft: the waiter has checked the
  /// table, so the items go to whatever order is open now (or a new one),
  /// under a NEW key — the old key's receipt would answer duplicate/409.
  Future<bool> resendDraft() async {
    final d = _openDraft;
    if (d == null || !d.conflict) return false;
    if (_sending.contains(d.tableId)) {
      _errorMessage = _sendingMessage;
      notifyListeners();
      return false;
    }
    try {
      final liveId = _cartIdOf(await _apiService.getCartItemsByTableId(d.tableId, fresh: true));
      var next = TableDraft.start(d.restaurantId, d.tableId, liveId);
      for (final l in d.allLines) {
        next = next.add(l);
      }
      await _saveDraft(next);
    } on ApiException catch (e) {
      _errorMessage = e.message;
      _sessionExpired = e.isAuth;
      notifyListeners();
      return false;
    }
    return flushDraft();
  }

  /// "Unlock & send" on a draft held by another device's table claim: frees
  /// the claim (waiter confirmed that device is not in use), then sends as
  /// [resendDraft] does.
  Future<bool> unlockTableAndResend() async {
    final d = _openDraft;
    if (d == null || !d.claimed || _isBusy) return false;
    final tid = d.tableId;
    if (_refuseWhileSending(tid)) return false;
    if (!ConnectivityService.instance.isOnline) {
      _errorMessage = 'No connection. Unlock the table when back online.';
      notifyListeners();
      return false;
    }
    // Held as sending while the release runs: no taps, edits or background
    // send on this table until the resend below takes over.
    _sending.add(tid);
    notifyListeners();
    try {
      await _apiService.releaseTableClaim(tid);
    } on ApiException catch (e) {
      _sessionExpired = e.isAuth;
      _errorMessage = e.httpStatus == 404 || e.code == 404
          ? 'This server cannot unlock tables yet. Update the server, or discard these items.'
          : e.message;
      notifyListeners();
      return false;
    } finally {
      _sending.remove(tid);
    }
    if (_openDraft?.tableId != tid) {
      // The waiter left the table meanwhile; its items stay held on the tablet.
      _errorMessage = 'Table unlocked, but it was closed before sending. Open it and tap Unlock & send again.';
      notifyListeners();
      return false;
    }
    return resendDraft();
  }

  /// Whether [tableId] has unsent items stored on this tablet.
  Future<bool> hasUnsentItems(String tableId) async {
    final rid = await _authService.getRestaurantId() ?? '';
    return await _drafts.load(rid, tableId) != null;
  }

  static const String unsentItemsMessage =
      'This table has items not sent yet. Open it and send the KOT first.';

  /// Drops the open table's unsent items (confirmed in the UI).
  Future<void> discardDraft() async {
    final d = _openDraft;
    if (d == null || _sending.contains(d.tableId)) return;
    _draft = null;
    _errorMessage = null;
    notifyListeners();
    await _drafts.delete(d.restaurantId, d.tableId);
  }

  Future<bool> _flush(TableDraft current, {required bool background}) async {
    final tid = current.tableId;
    // Background sends record problems on their own draft only.
    void say(String m) {
      if (!background) _errorMessage = m;
    }

    if (current.conflict || _sending.contains(tid)) {
      say(current.conflict
          ? (current.lastError ?? 'Unsent items on this table need attention.')
          : _sendingMessage);
      notifyListeners();
      return false;
    }
    _sending.add(tid);
    var d = current;
    var sent = false;
    try {
      var liveId = _cartIdOf(await _apiService.getCartItemsByTableId(tid, background: background, fresh: true));

      if (d.baselineCartId == null) {
        final pending = d.creatingLine;
        if (liveId.isEmpty && pending != null) {
          // An earlier createcart never answered and the table has no order
          // now: it may have reached an order that was billed since. Only the
          // waiter can tell, so never re-create it automatically.
          return await _markConflict(
            background,
            d,
            'An item from this table may already be on a bill that was closed. Check before sending it again.',
          );
        }
        if (liveId.isEmpty) {
          final first = d.lines.first;
          // Persist before sending, so a lost answer is recognised next time.
          d = d.copyWith(creatingLine: first, lines: d.lines.sublist(1));
          await _saveDraft(d);
          try {
            await _createCartLine(tid, first, background: background);
          } on ApiException catch (e) {
            // A refusal is a definite "not added": put the item back so it
            // can be edited or removed. Only a lost answer keeps it locked.
            if (!e.isNetwork) {
              d = d.copyWith(clearCreating: true, lines: [first, ...d.lines]);
            }
            rethrow;
          }
          liveId = _cartIdOf(await _apiService.getCartItemsByTableId(tid, background: background, fresh: true));
          if (liveId.isEmpty) {
            throw const ApiException('Could not open the order. Try again.');
          }
          d = d.copyWith(clearCreating: true, baselineCartId: liveId);
          await _saveDraft(d);
        } else if (pending != null &&
            _cartHasLine(await _apiService.getCartItemsByTableId(tid, background: background, fresh: true), pending)) {
          d = d.copyWith(clearCreating: true, baselineCartId: liveId);
          await _saveDraft(d);
        } else {
          return await _markConflict(
            background,
            d,
            'This table was opened on another device while these items were waiting.',
          );
        }
      } else if (d.baselineCartId != liveId) {
        return await _markConflict(
            background,
          d,
          liveId.isEmpty
              ? 'This table was billed or cleared while these items were waiting.'
              : 'This table has a new order since these items were added.',
        );
      }

      if (d.lines.isNotEmpty) {
        await _apiService.offlineSync(
          tableId: tid,
          idempotencyKey: d.key,
          lines: d.lines.map((l) => l.toSyncJson()).toList(),
          capturedAt: d.createdAt,
          background: background,
        );
      }
      await _saveDraft(d.copyWith(lines: const []));
      sent = true;
      final fresh = await _repriceAfterSync(tid, background: background);
      if (_isOpen(tid)) {
        _cartData = fresh;
        _cartStale = false;
        await _saveSnapshot();
      }
      markFloorDirty();
      return true;
    } on ApiException catch (e) {
      if (e.isAuth) {
        _sessionExpired = true;
        _stopSendAll = true;
      }
      if (sent) {
        if (_isOpen(tid)) _cartStale = true;
        say(_staleMessage);
        return false;
      }
      if (e.isSubscriptionLocked) {
        // Not a problem with these items: keep them queued as they are (never
        // held) and stop sending other tables until the renewal.
        _stopSendAll = true;
        say(subscriptionWaitMessage);
        await _saveDraft(d.copyWith(lastError: subscriptionWaitMessage));
        return false;
      }
      if (e.isTableClaimed) {
        return await _markConflict(background, d, e.claimMessage, claimed: true);
      }
      if (e.code == 409) {
        return await _markConflict(
            background,
          d,
          'These items were edited after a send that may have reached the server. Check the order before sending again.',
        );
      }
      final refusal = _refusalText(e);
      if (refusal != null) return await _markConflict(background, d, refusal);
      say(e.message);
      await _saveDraft(d.copyWith(lastError: e.message));
      return false;
    } catch (e) {
      say(friendlyError(e));
      return false;
    } finally {
      _sending.remove(tid);
      notifyListeners();
    }
  }

  /// A definite "no" from the server: retrying the same items can never
  /// succeed, so they wait for the waiter. Null = worth retrying (no signal,
  /// server error, timeout, rate limit). offline-sync puts its reason word in
  /// `status.message`, which lands in [ApiException.message].
  static const String subscriptionWaitMessage =
      'Subscription expired — items will send after renewal.';

  static String? _refusalText(ApiException e) {
    if (e.isNetwork || e.isAuth) return null;
    if (e.code >= 500 || e.code == 408 || e.code == 429 || e.code < 400) {
      return null;
    }
    return switch (e.message) {
      'no_cart' =>
        'This table was billed or cleared while these items were waiting.',
      'menu_not_found' || 'item_missing_menu' =>
        'An item was removed from the menu. Discard it and add it again.',
      'cart_locked_by_paid_split' =>
        'Part of this bill is already paid, so items cannot be added.',
      _ => 'The server refused these items: ${e.message}',
    };
  }

  static String _cartIdOf(List<Map<String, dynamic>> carts) =>
      carts.isEmpty ? '' : (carts.first['_id']?.toString() ?? '');

  Future<bool> _markConflict(
    bool background,
    TableDraft d,
    String why, {
    bool claimed = false,
  }) async {
    if (!background) _errorMessage = why;
    await _saveDraft(d.copyWith(conflict: true, claimed: claimed, lastError: why));
    return false;
  }

  Future<ApiEnvelope> _createCartLine(
    String tableId,
    DraftLine l, {
    bool background = false,
  }) => _apiService.createCartItem(
        background: background,
        tableId: tableId,
        cartId: '',
        menuId: l.isExtra ? null : l.menuId,
        menuPrice: l.unitPrice,
        variantId: l.variantId,
        addons: l.addons,
        isExtraAddon: l.isExtra,
        menuName: l.isExtra ? l.name : null,
        taxId: _consolidatedTax?['_id']?.toString(),
        taxName: _consolidatedTax?['name']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
        // Only used when the table has no cart, so there is no container charge yet.
        containerPrice: '0',
        quantity: l.quantity,
        description: l.description,
      );

  /// Did an earlier, unanswered createcart for [l] reach the server? The
  /// pending line is locked, so its quantity can only match exactly.
  bool _cartHasLine(List<Map<String, dynamic>> carts, DraftLine l) {
    final lines = carts.isEmpty ? null : carts.first['cartMenuData'];
    if (lines is! List) return false;
    return lines.whereType<Map>().any((raw) {
      final m = Map<String, dynamic>.from(raw);
      if (isKotLine(m) || m['cancel_status'] == 1) return false;
      final server = DraftLine(
        lineId: '',
        menuId: m['menu_id']?.toString(),
        name: m['menu_name']?.toString() ?? '',
        variantId: m['variant_id']?.toString(),
        addons: (m['addons'] as List? ?? const [])
            .whereType<Map>()
            .map((a) => Map<String, dynamic>.from(a))
            .toList(),
        quantity: int.tryParse(m['quantity']?.toString() ?? '') ?? 0,
        unitPrice: _num(m['individual_price']),
        description: m['description']?.toString() ?? '',
        isExtra: m['is_extra_addon'] == true,
      );
      return server.sameItemAs(l) && server.quantity == l.quantity;
    });
  }

  /// Returns the table's cart after the sync. `offline-sync` on api-server main
  /// only sums line prices, leaving GST, area charge and round-off stale, so one
  /// line's quantity is re-saved to make the server run full pricing.
  // lean: drop the re-save (and its request) once fatfox-api-server PR #294 is deployed.
  Future<List<Map<String, dynamic>>> _repriceAfterSync(
    String tid, {
    bool background = false,
  }) async {
    final carts = await _apiService.getCartItemsByTableId(tid, background: background, fresh: true);
    final lines = carts.isEmpty ? null : carts.first['cartMenuData'];
    final line = lines is List
        ? lines.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).where(
              (m) => !isKotLine(m) && m['cancel_status'] != 1,
            ).firstOrNull
        : null;
    if (line == null) return carts;
    try {
      final env = await _apiService.updateCartItemQuantity(
        background: background,
        cartId: _cartIdOf(carts),
        cartmenuId: line['_id'].toString(),
        quantity: int.tryParse(line['quantity']?.toString() ?? '') ?? 1,
        taxId: _consolidatedTax?['_id']?.toString(),
        taxValueType: _consolidatedTax?['value_type']?.toString(),
        taxValueAmount: _consolidatedTax?['value_amount']?.toString(),
        containerPrice: _num(carts.first['container_price']) > 0
            ? carts.first['container_price'].toString()
            : '0',
      );
      final repriced = env.mapList;
      return repriced.isNotEmpty && repriced.first.containsKey('cartMenuData')
          ? repriced
          : carts;
    } on ApiException catch (e) {
      if (e.isAuth) rethrow;
      // Items are on the server; totals catch up on the next cart write.
      debugPrint('[Fatfox POS] reprice after sync failed: $e');
      return carts;
    }
  }

  /// Cancel a KOT'd line with a reason (row kept, excluded from pricing).
  Future<bool?> cancelKotLine(String cartmenuId, {required String reason}) {
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
  /// print failed afterwards. Returns `null` if another action is in flight.
  Future<bool?> sendKotOrder() async {
    if (_isBusy) return null;
    if (ConnectivityService.instance.syncOff) {
      _errorMessage = _syncOffPrint;
      notifyListeners();
      return false;
    }
    final openTable = resolvedTableId;
    // Paper must match the server: send unsent items, then work only from a
    // cart read just now (a send already returns one). This also proves the
    // server is reachable before anything prints.
    _isBusy = true;
    notifyListeners();
    // One lock for the whole send + print; released however it ends.
    try {
      return await _sendKotLocked(openTable);
    } on ApiException catch (e) {
      _errorMessage = e.message;
      _sessionExpired = e.isAuth;
    } catch (e) {
      _errorMessage = friendlyError(e);
    } finally {
      _isBusy = false;
      notifyListeners();
    }
    return false;
  }

  Future<bool> _sendKotLocked(String openTable) async {
    final hadDraft = _openDraft != null;
    var ready = await flushDraft();
    if (ready && (!hadDraft || _cartStale) && _isOpen(openTable)) {
      ready = await _refreshCart(openTable);
    }
    // The waiter may have left the table while it was sending.
    if (!ready || !_isOpen(openTable)) return false;
    final tid = resolvedTableId;
    final cid = cartId;
    if (tid.isEmpty || cid.isEmpty) {
      _errorMessage = 'No items on this table yet';
      return false;
    }

    _errorMessage = null;
    printError = null;
    notifyListeners();

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

    markFloorDirty();
    return true;
  }

  // ============================================================
  // Discounts
  // ============================================================

  Future<List<Map<String, dynamic>>> listDiscounts({
    String searchName = '',
  }) async {
    // Unsent items are not on the server cart the discount is checked against.
    final serverTotal = _num(cart?['total_price']);
    final amount = _serverSubTotal > 0 ? _serverSubTotal : serverTotal;
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

  Future<bool?> applyDiscount(String discountId) {
    final cid = cartId;
    if (cid.isEmpty || discountId.isEmpty) return Future.value(false);
    return _write(
      () => _apiService.setCartDiscount(cartId: cid, discountId: discountId),
    );
  }

  Future<bool?> clearDiscount() {
    final cid = cartId;
    if (cid.isEmpty) return Future.value(false);
    return _write(() => _apiService.removeCartDiscount(cartId: cid));
  }

  // ============================================================
  // Bill + settle
  // ============================================================

  /// Floor print: bind table cart temporarily, print, then restore prior POS bind
  /// so an open food-categories screen is not left on the wrong table.
  ///
  /// Owns `_isBusy` for the whole prepare+print+restore window. Returns
  /// `(skipped: true, …)` if another action is already in flight.
  Future<({bool skipped, String? error})> printBillForFloorTable({
    required String tableId,
    required String areaId,
  }) async {
    if (_isBusy) return (skipped: true, error: null);
    _isBusy = true;
    _errorMessage = null;
    printError = null;
    notifyListeners();

    final prevTableId = _activeTableId;
    final prevAreaId = _activeAreaId;
    final prevCart = List<Map<String, dynamic>>.from(_cartData);
    final prevDetails = _tableDetails;
    final prevTax = List<Map<String, dynamic>>.from(_taxConfig);
    final prevConsolidated = _consolidatedTax;
    final prevActiveTable = _activeTable;
    final prevStale = _cartStale;
    _activeTable = null;
    try {
      final prep = await prepareTableForBill(tableId: tableId, areaId: areaId);
      if (prep != null) return (skipped: false, error: prep);
      return await printBill(holdLock: true);
    } finally {
      _activeTableId = prevTableId;
      _activeAreaId = prevAreaId;
      _cartData = prevCart;
      _tableDetails = prevDetails;
      _taxConfig = prevTax;
      _consolidatedTax = prevConsolidated;
      _activeTable = prevActiveTable;
      _cartStale = prevStale;
      _isBusy = false;
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
    final rid = await _authService.getRestaurantId() ?? '';
    if (await _drafts.load(rid, tableId) != null) return unsentItemsMessage;
    try {
      final results = await Future.wait<Object?>([
        _apiService.viewTableById(tableId),
        _apiService.getCartItemsByTableId(tableId),
        _bestEffortTax(),
      ]);
      _tableDetails =
          results[0] as Map<String, dynamic>? ?? {'table_id': tableId};
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

  /// KOT and bill both print from local state before the server hears about
  /// it, so with Sync off they would hand out paper the server never recorded.
  static const String _syncOffPrint =
      'Sync is off. Turn Sync on to print KOT or bill.';

  /// Print the customer bill and mark the table PRINTED (admin "KOT + Bill").
  ///
  /// Returns `(skipped: true)` if busy; `(skipped: false, error: null)` on
  /// success; `(skipped: false, error: …)` on failure.
  ///
  /// When [holdLock] is true the caller already owns `_isBusy` and must clear
  /// it (used by [printBillForFloorTable]).
  Future<({bool skipped, String? error})> printBill({
    String? paymentMode,
    bool holdLock = false,
  }) async {
    if (!holdLock) {
      if (_isBusy) return (skipped: true, error: null);
      _isBusy = true;
      _errorMessage = null;
      printError = null;
      notifyListeners();
    }

    try {
      return (skipped: false, error: await _printBillLocked(paymentMode));
    } finally {
      if (!holdLock) {
        _isBusy = false;
        notifyListeners();
      }
    }
  }

  /// [printBill] under the caller's lock; returns the error, or null.
  Future<String?> _printBillLocked(String? paymentMode) async {
    final tid = resolvedTableId;
    if (ConnectivityService.instance.syncOff) return _syncOffPrint;
    // Items mid-send are not on the server cart yet (floor path included).
    // Returned, not set on _errorMessage: the floor path restores the open
    // table afterwards and must not leave this text on its screen.
    if (_sending.contains(tid)) return _sendingMessage;
    final held = _openDraft;
    if (held != null && held.conflict) {
      final n = held.itemCount;
      return '$n item${n == 1 ? '' : 's'} on this table ${n == 1 ? 'is' : 'are'} held: '
          '${held.lastError ?? 'check the order.'} ${held.claimed ? 'Unlock' : 'Send'} or discard ${n == 1 ? 'it' : 'them'} first.';
    }
    if (tid.isEmpty || !await _refreshCart(tid) || cartId.isEmpty) {
      // Paper must match the server: never print from a cart the tablet only
      // remembers (opened offline, or read before other devices' changes).
      return tid.isEmpty || _errorMessage == null
          ? 'No items on this table yet'
          : _errorMessage!;
    }
    // Pinned now: later awaits must not pick up another table's state.
    final cid = cartId;
    final snapshot = cart;
    final number = tableNumber;

    String? failure;
    try {
      if (hasUnsentKotItems) {
        return 'Send KOT to kitchen before printing the bill';
      }
      final data = await BillBuilder(_apiService).build(
        tableId: tid,
        tableNumber: number,
        paymentMode: paymentMode,
        cartSnapshot: snapshot,
        taxRows: _taxConfig,
      );
      if (data == null) return 'No active cart found for this table';
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
    } on ApiException catch (e) {
      failure = e.message;
      _sessionExpired = e.isAuth;
    } catch (e) {
      failure = friendlyError(e);
      printError = failure;
    }
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
  /// Returns `null` if another action is in flight.
  Future<bool?> discardCart() async {
    if (_isBusy) return null;
    if (_refuseWhileSending(resolvedTableId)) return false;
    final cid = cartId;
    final d = _openDraft;
    if (cid.isEmpty) {
      if (d != null) await _drafts.delete(d.restaurantId, d.tableId);
      _draft = null;
      _cartData = [];
      await _saveSnapshot(); // or a later offline reload repaints the old cart
      _errorMessage = null;
      notifyListeners();
      return true;
    }

    _isBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _apiService.deleteCart(cid);
      if (d != null) await _drafts.delete(d.restaurantId, d.tableId);
      _draft = null;
      _cartData = [];
      await _saveSnapshot();
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
  /// Returns `null` if another action is in flight.
  Future<bool?> settleAndPrintBill({String paymentType = 'CASH'}) async {
    if (_isBusy) return null;
    if (_refuseWhileSending(resolvedTableId)) return false;
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
      await _saveSnapshot();
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
