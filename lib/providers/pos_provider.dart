import 'dart:async';

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
import '../services/offline_pricing.dart';
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
  String? _extraAddonRestaurantId; // restaurant_id owner of _extraAddonRawGroups
  bool _extraAddonsLoading = false;
  Future<void>? _extraAddonsLoad;
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

  void clearFloorDirty() {
    _floorDirty = false;
    _extraAddonRawGroups = null;
    _extraAddonRestaurantId = null;
    _enrichedItemMemoryCache.clear();
    _selectedCategoryId = null;
  }

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
      if (_extraAddonRestaurantId != _restaurantId) return const [];
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
    ...?_openDraft?.printedLines.map((l) => l.toCartLineMap(printed: true)),
    ...?_openDraft?.unprintedLines.map((l) => l.toCartLineMap()),
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

  /// Whether the customer bill has been printed for this table (online status or offline pending ops).
  bool get isBillPrinted {
    final s = tableStatus;
    if (s == 'PRINTED' || s == 'PAID') return true;
    return _openDraft?.pendingOps.contains('PRINTED') ?? false;
  }

  /// Phase 1 safety rule: Release only after the bill status is durable,
  /// unless device pref `kot_enable_release_table` matches admin exception.
  bool get canRelease {
    if (_cartStale) return false;
    if (cartId.isEmpty || cartMenuItems.isEmpty) return false;
    if (hasUnsentKotItems || hasUnprintedItems) return false;
    if (isBillPrinted) return true;
    final allowKotRelease = _receiptPrefs?.kotEnableReleaseTable ?? false;
    if (!allowKotRelease) return false;
    final s = tableStatus;
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
  /// Concurrent callers share one in-flight Future so enrich never expands
  /// against a null cache while Extra-rail load is mid-flight.
  Future<void> ensureExtraAddonsLoaded({bool force = false}) async {
    if (!force &&
        _extraAddonRawGroups != null &&
        _extraAddonRestaurantId == _restaurantId) {
      return;
    }
    if (_extraAddonsLoad != null) {
      await _extraAddonsLoad;
      if (!force ||
          (_extraAddonRawGroups != null &&
              _extraAddonRestaurantId == _restaurantId)) {
        return;
      }
    }
    final load = () async {
      _extraAddonsLoading = true;
      notifyListeners();
      try {
        final rid = _restaurantId;
        final groups = await _apiService.getAllAvailableAddons();
        _extraAddonRawGroups = groups;
        _extraAddonRestaurantId = rid;
        if (_errorMessage == 'Failed to load extra add-ons') {
          _errorMessage = null;
        }
      } catch (e) {
        debugPrint('[Fatfox POS] Extra add-ons load failed: $e');
        final cached = await _menuCache.load(_restaurantId);
        if (cached != null && cached.extraAddons.isNotEmpty) {
          _extraAddonRawGroups = cached.extraAddons;
          _extraAddonRestaurantId = _restaurantId;
        } else {
          _extraAddonRawGroups = null; // allow retry on re-select
          _extraAddonRestaurantId = null;
          _errorMessage = 'Failed to load extra add-ons';
        }
      } finally {
        _extraAddonsLoading = false;
        _extraAddonsLoad = null;
        notifyListeners();
      }
    }();
    _extraAddonsLoad = load;
    await load;
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
  final Map<String, MenuItem> _enrichedItemMemoryCache = {};

  /// getmenu returns `{ variant_id, price }` / `{ addon_id }` without names —
  /// join variant catalog + AllAvailableAddons like admin.
  /// Works offline by serving disk-cached item details or catalog-joined stubs.
  Future<MenuItem?> enrichMenuItem(MenuItem item) async {
    if (item.id.isEmpty) return item;

    // 1. Check in-memory cache first
    if (_enrichedItemMemoryCache.containsKey(item.id)) {
      return _enrichedItemMemoryCache[item.id];
    }

    // 2. Offline flow: check persistent disk cache or build catalog-joined item
    if (!ConnectivityService.instance.isOnline) {
      try {
        final cachedRaw = await _menuCache.loadEnrichedItem(_restaurantId, item.id);
        if (cachedRaw != null) {
          final enriched = MenuItem.fromJson(cachedRaw);
          final variants = _joinVariantNames(
            enriched.variants.isNotEmpty ? enriched.variants : item.variants,
          );
          final addons = _expandAddonsFromCatalog(
            cachedRaw,
            enriched.addons.isNotEmpty ? enriched.addons : item.addons,
          );
          final result = MenuItem(
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
            addons: addons,
            customisable: enriched.customisable || item.customisable,
            isFavorite: enriched.isFavorite || item.isFavorite,
          );
          _enrichedItemMemoryCache[item.id] = result;
          return result;
        }
      } catch (e) {
        debugPrint('[Fatfox POS] Offline loadEnrichedItem error: $e');
      }

      // Fallback offline: build joined item from current _allItems & catalog
      final fallbackVariants = _joinVariantNames(item.variants);
      final fallbackAddons = _expandAddonsFromCatalog({}, item.addons);
      final fallbackItem = MenuItem(
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
        variants: fallbackVariants,
        addons: fallbackAddons,
        customisable: item.customisable || fallbackVariants.isNotEmpty || fallbackAddons.isNotEmpty,
        isFavorite: item.isFavorite,
      );
      _enrichedItemMemoryCache[item.id] = fallbackItem;
      return fallbackItem;
    }

    // 3. Online flow: fetch fresh details from API and update disk/memory caches
    try {
      await _ensureVariantCatalog();
      await ensureExtraAddonsLoaded();
      final raw = await _apiService.getMenuById(item.id);
      if (raw == null) {
        final fallback = MenuItem(
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
          addons: _expandAddonsFromCatalog({}, item.addons),
          customisable: item.customisable,
          isFavorite: item.isFavorite,
        );
        return fallback;
      }

      // Persist raw detail to disk cache for future offline use
      unawaited(_menuCache.saveEnrichedItem(_restaurantId, item.id, raw));

      final enriched = MenuItem.fromJson(raw);
      final variants = _joinVariantNames(
        enriched.variants.isNotEmpty ? enriched.variants : item.variants,
      );
      final addons = _expandAddonsFromCatalog(
        raw,
        enriched.addons.isNotEmpty ? enriched.addons : item.addons,
      );
      final result = MenuItem(
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
        addons: addons,
        customisable: enriched.customisable || item.customisable,
        isFavorite: enriched.isFavorite || item.isFavorite,
      );
      _enrichedItemMemoryCache[item.id] = result;
      return result;
    } on ApiException catch (e) {
      if (e.isAuth) {
        _sessionExpired = true;
        _errorMessage = e.message;
        notifyListeners();
      }
      return MenuItem(
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
        addons: _expandAddonsFromCatalog({}, item.addons),
        customisable: item.customisable,
        isFavorite: item.isFavorite,
      );
    } catch (e) {
      debugPrint('[Fatfox POS] enrichMenuItem failed: $e');
      return MenuItem(
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
        addons: _expandAddonsFromCatalog({}, item.addons),
        customisable: item.customisable,
        isFavorite: item.isFavorite,
      );
    }
  }

  /// Mirror admin `viewMenubyId` + `viewAddons.find(_id === addon.addon_id)`:
  /// expand getmenu `{addon_id}` stubs into active catalog `value[]` options.
  List<MenuAddon> _expandAddonsFromCatalog(
    Map<String, dynamic> raw,
    List<MenuAddon> alreadyParsed,
  ) {
    if (alreadyParsed.any((a) => a.valueName.trim().isNotEmpty)) {
      return alreadyParsed;
    }
    final groups = _extraAddonRawGroups;
    if (groups == null || groups.isEmpty) return alreadyParsed;

    final catalogById = <String, Map<String, dynamic>>{};
    for (final g in groups) {
      final id = g['_id']?.toString() ?? '';
      if (id.isNotEmpty) catalogById[id] = g;
    }

    final stubList = <dynamic>[];
    for (final key in [
      'addons',
      'addOns',
      'addon',
      'addonData',
      'addon_data',
      'addon_ids',
      'addon_groups',
      'addonGroups',
      'customisation',
      'customisations',
      'customization',
      'customizations',
      'item_addons',
    ]) {
      if (raw[key] is List) {
        stubList.addAll(raw[key] as List);
      }
    }

    if (stubList.isEmpty) return alreadyParsed;

    final out = <MenuAddon>[];
    for (final entry in stubList) {
      if (entry is! Map) continue;
      final addonId = entry['addon_id']?.toString() ??
          entry['_id']?.toString() ??
          entry['id']?.toString() ??
          '';
      if (addonId.isEmpty) continue;
      final cat = catalogById[addonId];
      if (cat == null) continue;
      final values = cat['value'];
      if (values is! List) continue;
      final groupName =
          (cat['displayname'] ?? cat['name'] ?? cat['title'] ?? '').toString();
      for (final v in values) {
        if (v is! Map) continue;
        final status = v['status'];
        if (status != 1 && status != '1') continue;
        final valMap = Map<String, dynamic>.from(v);
        out.add(
          MenuAddon.fromJson({
            ...valMap,
            'addon_id': addonId,
            'group_name': groupName,
            'valuename': valMap['valuename'] ??
                valMap['value_name'] ??
                valMap['name'] ??
                valMap['displayname'],
          }),
        );
      }
    }
    return out.isNotEmpty ? out : alreadyParsed;
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
    _cartFromSnapshot = false;
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
        if (cached.extraAddons.isNotEmpty) {
          _extraAddonRawGroups = cached.extraAddons;
          _extraAddonRestaurantId = restaurantId;
        }
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
          _bestEffortExtraAddons(),
        ]);
        _tableDetails = results[0] as Map<String, dynamic>?;
        final catMaps = results[1] as List<Map<String, dynamic>>;
        final itemMaps = results[2] as List<Map<String, dynamic>>;
        _categories = catMaps.map(MenuCategory.fromJson).toList();
        _setSortedMenuItems(itemMaps.map(MenuItem.fromJson).toList());
        final taxRows = results[3] as List<Map<String, dynamic>>;
        final variantMaps = results[4] as List<Map<String, dynamic>>;
        final deptMaps = results[5] as List<Map<String, dynamic>>;
        final extraAddonMaps = results[6] as List<Map<String, dynamic>>;
        _applyCatalogExtras(
          taxRows: taxRows,
          variantMaps: variantMaps,
          deptMaps: deptMaps,
        );
        if (extraAddonMaps.isNotEmpty) {
          _extraAddonRawGroups = extraAddonMaps;
          _extraAddonRestaurantId = restaurantId;
        }

        await _menuCache.save(
          restaurantId: restaurantId,
          categories: catMaps,
          items: itemMaps,
          taxRows: taxRows,
          variants: variantMaps,
          departments: deptMaps,
          extraAddons: extraAddonMaps,
        );
        _menuCachedAt = DateTime.now();
        // Warm the enriched item cache for customizable items (variants & add-ons)
        unawaited(_warmCustomisableItemsCache(_allItems));
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

  /// Background warming of item variant/addon details for offline support.
  Future<void> _warmCustomisableItemsCache(List<MenuItem> items) async {
    final customisableItems =
        items.where((i) => i.needsCustomisation).toList();
    for (final item in customisableItems) {
      if (item.id.isEmpty) continue;
      try {
        final raw = await _apiService.getMenuById(item.id);
        if (raw != null) {
          await _menuCache.saveEnrichedItem(_restaurantId, item.id, raw);
          final enriched = MenuItem.fromJson(raw);
          _enrichedItemMemoryCache[item.id] = enriched;
        }
      } catch (e) {
        debugPrint('[Fatfox POS] Warm cache failed for item ${item.id}: $e');
      }
    }
  }

  /// No server: open the table from the cached menu and the last cart this
  /// tablet saw, so the waiter can keep adding items. False when there is no
  /// cached menu to show.
  Future<bool> _openOffline(String tableId, CachedMenuSnapshot? cached) async {
    if (cached == null || !cached.hasCatalog) return false;
    // A cold start has nothing in memory yet.
    _categories = cached.categories;

    // Load full enriched variant/addon details from disk cache if available
    final enrichedList = <MenuItem>[];
    for (final item in cached.items) {
      var workingItem = item;
      if (item.id.isNotEmpty &&
          (item.customisable || item.hasVariants || item.variants.isEmpty)) {
        final cachedRaw =
            await _menuCache.loadEnrichedItem(_restaurantId, item.id);
        if (cachedRaw != null) {
          workingItem = MenuItem.fromJson(cachedRaw);
        }
      }

      enrichedList.add(workingItem);
    }

    _allItems = enrichedList;
    _menuCachedAt = cached.savedAt;
    if (cached.extraAddons.isNotEmpty) {
      _extraAddonRawGroups = cached.extraAddons;
      _extraAddonRestaurantId = _restaurantId;
    } else {
      _extraAddonRawGroups = null;
      _extraAddonRestaurantId = null;
    }
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
    _cartAt = snap?.at;
    // A copy from the tablet: KOT and bill must re-read the server first
    // (an offline print works from this copy — see [_canPrintOffline]), but
    // never from one an upload already left behind.
    _cartStale = true;
    _cartFromSnapshot = !(snap?.stale ?? false);
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

  Future<List<Map<String, dynamic>>> _bestEffortExtraAddons() async {
    try {
      return await _apiService.getAllAvailableAddons();
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
      _cartFromSnapshot = false;
      _cartAt = DateTime.now();
      await _saveSnapshot();
      // The last number the server issued: offline paper continues from it.
      await OfflineBillNumbers.remember(
        _restaurantId,
        cart?['order_no'] ?? cart?['qr_order_no'],
      );
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
        _cartFromSnapshot = !snap.stale;
        _cartAt = snap.at;
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
      _cartFromSnapshot = false;
      _cartAt = DateTime.now();
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
    if (d.printedLines.any((l) => l.lineId == lineId)) {
      // Already on a KOT the kitchen holds — same rule as a server KOT'd line.
      _errorMessage =
          'This item is already sent to the kitchen. Cancel it instead.';
      notifyListeners();
      return false;
    }
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

  /// The cart on screen is the tablet's own copy, never read from the server
  /// this session. Unlike [_cartStale] that is not a warning about prices the
  /// server may have changed since — nothing was sent, so this copy is the
  /// whole truth the tablet has, and an offline print may use it.
  bool _cartFromSnapshot = false;

  /// When the cart on screen was last true: a server read, or the moment the
  /// snapshot it came from was written. Paper is never printed from a copy
  /// older than [offlinePrintMaxCartAge].
  DateTime? _cartAt;
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
    final tid = resolvedTableId;
    // Bills already taken go up first: each owns the sitting it was printed
    // for, and the live draft below is the NEXT sitting on the same table.
    if (ConnectivityService.instance.isOnline) {
      await _syncSettlementsFor(tid, background: false);
    }
    // Read only NOW: the waiter can add items while that runs, and a draft
    // captured before it would send a copy from before those taps.
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
      _extraAddonRawGroups = null;
      _extraAddonRestaurantId = null;
      _enrichedItemMemoryCache.clear();
    }
    final draftTables = (await _drafts.all(rid)).map((d) => d.tableId).toList();
    DraftCartStore.pendingTables.value = draftTables.length;
    await _drafts.refreshPendingSettlements(rid);
    // Tables that owe only a settlement have no draft row of their own.
    final tables = [
      ...draftTables,
      ...(await _drafts.allSettlements(rid))
          .where((s) => s.pending && !draftTables.contains(s.tableId))
          .map((s) => s.tableId)
          .toSet(),
    ];
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
    if (_consolidatedTax == null) {
      // Items cannot be priced, but money already taken still has to go up.
      var settled = 0;
      for (final tid in tables) {
        if (await _syncSettlementsFor(tid, background: true) > 0) settled++;
      }
      return settled;
    }

    _sendingAll = true;
    _stopSendAll = false;
    var sent = 0;
    // A table is one send, whether it owed a bill, items, or both.
    final counted = <String>{};
    try {
      for (final tid in tables) {
        // Bills taken on THIS table first, oldest sitting first: each carries
        // its own items, and the live draft below is a later sitting that must
        // never be uploaded onto one of them.
        if (await _syncSettlementsFor(tid, background: true) > 0 &&
            counted.add(tid)) {
          sent++;
        }
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
        if (await _flush(d, background: true) && counted.add(tid)) sent++;
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
    // A row kept only to replay a print's status holds no items.
    return (await _drafts.load(rid, tableId))?.hasItems ?? false;
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
      // Held items may be re-sent to a different order, so a status printed
      // for the old one can never be replayed.
      if (current.conflict && current.pendingOps.isNotEmpty) {
        await _saveDraft(current.copyWith(clearOps: true));
      }
      return false;
    }
    _sending.add(tid);
    var d = current;
    var sent = false;
    try {
      final live = await _apiService.getCartItemsByTableId(tid, background: background, fresh: true);
      var liveId = _cartIdOf(live);
      // Read before this send's own writes: a table already billed must never
      // be walked backwards by a status printed offline.
      final liveStatus = live.isEmpty
          ? ''
          : (live.first['table_status']?.toString() ?? '');

      if (!d.hasItems && d.baselineCartId == null) {
        // Nothing but a status to replay, and no order it could belong to.
        return await _markConflict(
          background,
          d,
          'That order is no longer on this table.',
        );
      }

      if (d.hasItems) {
        // From here the tablet's copy of this table is behind the server, even
        // if an answer never comes back (a createcart below included).
        // Cleared by the fresh read at the end.
        await _drafts.markSnapshotStale(d.restaurantId, tid);
      }

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
          // The oldest batch opens the order: a printed line if there is one.
          final fromPrinted = d.printedLines.isNotEmpty;
          final first = fromPrinted ? d.printedLines.first : d.lines.first;
          // Persist before sending, so a lost answer is recognised next time.
          d = d.copyWith(
            creatingLine: first,
            lines: fromPrinted ? d.lines : d.lines.sublist(1),
            printedLines: fromPrinted ? d.printedLines.sublist(1) : d.printedLines,
          );
          await _saveDraft(d);
          try {
            await _createCartLine(tid, first, background: background);
          } on ApiException catch (e) {
            // A refusal is a definite "not added": put the item back so it
            // can be edited or removed. Only a lost answer keeps it locked.
            if (!e.isNetwork) {
              d = d.copyWith(
                clearCreating: true,
                lines: fromPrinted ? d.lines : [first, ...d.lines],
                printedLines:
                    fromPrinted ? [first, ...d.printedLines] : d.printedLines,
              );
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

      // Order matters: the printed batch, then its status, then whatever was
      // added after the print (which that status must not touch).
      if (d.printedLines.isNotEmpty) {
        await _apiService.offlineSync(
          tableId: tid,
          idempotencyKey: d.printedKey ?? d.key,
          lines: d.printedLines.map((l) => l.toSyncJson()).toList(),
          capturedAt: d.createdAt,
          background: background,
        );
        sent = true;
        d = d.copyWith(printedLines: const []);
        await _saveDraft(d);
      }
      if (d.pendingOps.isNotEmpty) {
        // [onProgress] keeps `d` in step, so a status refused mid-way leaves
        // the ones that already landed out of the saved draft.
        await _replayPrintOps(
          d,
          liveStatus,
          background: background,
          onProgress: (progressed) => d = progressed,
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
        _cartFromSnapshot = false;
        _cartAt = DateTime.now();
        await _saveSnapshot();
      } else {
        // A background send for another table: its stored copy must not stay
        // at the one from before these items landed, or a later offline open
        // would print a ticket without them.
        await _drafts.saveSnapshot(d.restaurantId, tid, cart: fresh);
      }
      markFloorDirty();
      return true;
    } on ApiException catch (e) {
      if (e.isAuth) {
        _sessionExpired = true;
        _stopSendAll = true;
      }
      if (sent) {
        // Sent, prices unread: the tablet's copy is now behind the server.
        if (_isOpen(tid)) {
          _cartStale = true;
          _cartFromSnapshot = false;
        }
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
      // A claim refusal names the holding device and offers Unlock, so it is
      // held apart from the "may already have landed" 409.
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

  /// A KOT or bill already on paper whose status the server never got. Said
  /// out loud: the waiter must not assume the order advanced.
  static const String printNotRecordedMessage =
      'A KOT or bill printed offline could not be recorded on this order. Check the order.';

  /// Applies the statuses of prints that already happened on paper, oldest
  /// first. Dropped — never forced — when the order they were printed from is
  /// gone or has already moved past them.
  Future<void> _replayPrintOps(
    TableDraft d,
    String liveStatus, {
    required bool background,
    required void Function(TableDraft) onProgress,
  }) async {
    final cid = d.baselineCartId ?? '';
    if (cid.isEmpty || liveStatus == 'PRINTED' || liveStatus == 'PAID') {
      if (!background) _errorMessage = printNotRecordedMessage;
      final dropped = d.copyWith(
        clearOps: true,
        lastError: printNotRecordedMessage,
      );
      onProgress(dropped);
      await _saveDraft(dropped);
      return;
    }
    for (final status in TableDraft.opOrder) {
      if (!d.pendingOps.contains(status)) continue;
      // The replay route, never the live one: this print happened on paper
      // while there was no signal, and the kitchen must not be fired again.
      // A refusal (e.g. 422 on the capture time) throws out of here, so the
      // status stays queued and the waiter is told — never silently dropped.
      try {
        await _apiService.offlineStatus(
          cartId: cid,
          tableStatus: status,
          idempotencyKey: _statusKey(d, status),
          capturedAt: d.createdAt,
          background: background,
        );
      } on ApiException catch (e) {
        if (e.isNetwork || e.isAuth) rethrow;
        // A definite refusal (e.g. 422 on the capture time). The status is a
        // print that really happened, so it stays queued for the next pass —
        // and the reason is said out loud rather than swallowed.
        if (!background) _errorMessage = e.message;
        final held = d.copyWith(lastError: e.message);
        onProgress(held);
        await _saveDraft(held);
        return;
      }
      // One at a time: a refused PRINTED must not make the server re-live a
      // KOT_PRINT it already has.
      d = d.copyWith(pendingOps: [...d.pendingOps]..remove(status));
      onProgress(d);
      await _saveDraft(d);
    }
  }

  /// One key per (sitting, status): a repeat is the same replay, never a
  /// second application of the status.
  static String _statusKey(TableDraft d, String status) =>
      '${d.printedKey ?? d.key}:$status';

  Future<bool> _markConflict(
    bool background,
    TableDraft d,
    String why, {
    bool claimed = false,
  }) async {
    // A parked draft may be re-sent to a different order, so a status printed
    // for the old one can never be replayed — it goes, and is said out loud.
    final text = d.pendingOps.isEmpty ? why : '$why $printNotRecordedMessage';
    if (!background) _errorMessage = text;
    await _saveDraft(
      d.copyWith(conflict: true, claimed: claimed, lastError: text, clearOps: true),
    );
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
      final addonRaw = m['addon'] ?? m['addonData'] ?? m['addons'];
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
    // No signal: the kitchen still needs its ticket.
    if (_canPrintOffline) return _printKotOffline();
    final hadDraft = _openDraft != null;
    var ready = await flushDraft();
    if (ready && (!hadDraft || _cartStale) && _isOpen(openTable)) {
      ready = await _refreshCart(openTable);
    }
    // The waiter may have left the table while it was sending.
    if (!ready || !_isOpen(openTable)) {
      // A refused send is often how the tablet learns the signal is gone:
      // print from what it holds rather than asking for a second KOT press.
      if (!_isOpen(openTable)) return false;
      if (_canPrintOffline) return await _printKotOffline();
      if (_offlinePrint && _offlinePrintBlocked == _offlineCopyTooOld) {
        _errorMessage = _offlineCopyTooOld;
      }
      return false; 
    }
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
      await _printKotTickets(kotItems);
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

  /// One ticket per kitchen department, with ESC/POS autocut between stations.
  Future<void> _printKotTickets(
    List<CartLineItem> kotItems, {
    bool offline = false,
  }) async {
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
        offline: offline,
      );
      await _printer.printBytes(bytes, role: PrinterRole.kot);
      if (i < groups.length - 1) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  /// No signal: print the kitchen ticket from what the tablet holds, then
  /// SEAL what went on paper — those lines read as KOT'd here, ride their own
  /// batch to the server, and carry a KOT_PRINT to replay. `KOT` is never
  /// queued: that status is what fires the kitchen display, and the food is
  /// already being cooked from this ticket.
  Future<bool> _printKotOffline() async {
    final tid = resolvedTableId;
    if (tid.isEmpty || cartMenuItems.isEmpty) {
      _errorMessage = 'No items on this table yet';
      return false;
    }
    final held = _openDraft;
    if (held != null && held.conflict) {
      // Held items may belong to another order; they must not be sealed into
      // this one, and a ticket without them would be wrong.
      _errorMessage = held.lastError ?? 'Unsent items on this table need attention.';
      return false;
    }
    _errorMessage = null;
    printError = null;
    notifyListeners();

    var kotItems = _kotLinesFromMaps(
      cartMenuItems
          .where((i) => i['kotprint_status'] != 1 && i['kotprint_status'] != '1')
          .toList(),
    );
    if (kotItems.isEmpty) kotItems = printCartLines;
    try {
      await _printKotTickets(kotItems, offline: true);
    } catch (e) {
      // Nothing reached the paper, so there is nothing to seal or replay.
      printError = friendlyError(e);
      debugPrint('[Fatfox POS] Offline KOT print error: $e');
      return false;
    }
    await _queuePrintStatus('KOT_PRINT');
    markFloorDirty();
    return true;
  }

  /// Records a print that only happened on paper: the lines just printed are
  /// sealed under their own key and [status] waits for the reconnect.
  Future<void> _queuePrintStatus(String status, {String? billNumber}) async {
    final tid = resolvedTableId;
    if (_restaurantId.isEmpty || tid.isEmpty) return;
    final d = _openDraft ?? TableDraft.start(_restaurantId, tid, cartId);
    await _saveDraft(d.sealPrinted(status).copyWith(billNumber: billNumber));
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
    final prevFromSnapshot = _cartFromSnapshot;
    final prevCartAt = _cartAt;
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
      _cartFromSnapshot = prevFromSnapshot;
      // A floor bill reads ANOTHER table: its freshness must not be left
      // attached to the copy the open table is restored to.
      _cartAt = prevCartAt;
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
    // The floor list has no menu, tax or cart for this table on the tablet, so
    // it can only bill what the server answers with.
    if (!ConnectivityService.instance.isOnline) {
      return 'No connection. Open the table to print its bill.';
    }
    final rid = await _authService.getRestaurantId() ?? '';
    _restaurantId = rid;
    if (await hasUnsentItems(tableId)) return unsentItemsMessage;
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

  /// Not talking to the server — no signal, or Sync switched off by hand.
  /// Both print from the tablet and replay what happened on the reconnect:
  /// everything is queued, so the switch is not a reason to refuse paper. What
  /// gates a print is whether the tablet's own copy is good
  /// ([_offlinePrintBlocked]); anything that genuinely needs the network is
  /// still refused.
  bool get _offlinePrint => !ConnectivityService.instance.isOnline;

  /// How old the tablet's copy of a cart may be and still be put on paper.
  /// Far shorter than the menu's cache rule: a menu barely moves during a
  /// shift, while another device can change an order minute to minute.
  static const Duration offlinePrintMaxCartAge = Duration(minutes: 30);

  static const String _offlineCopyTooOld =
      'This order was last read too long ago to print from the tablet. '
      'Reconnect and try again.';

  /// Why an offline print is refused, or null when the tablet's copy of the
  /// cart is good enough to put on paper. Asked only while there is no signal.
  String? get _offlinePrintBlocked {
    // Items reached the server and their prices came back unread: that paper
    // could not match the order. The re-read path reports this one.
    if (_cartStale && !_cartFromSnapshot) return _staleMessage;
    if (cartId.isNotEmpty &&
        !_freshEnough(_cartAt, maxAge: offlinePrintMaxCartAge)) {
      return _offlineCopyTooOld;
    }
    return null;
  }

  bool get _canPrintOffline => _offlinePrint && _offlinePrintBlocked == null;

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
    if (_canPrintOffline) return _printBillOffline(tid, paymentMode);
    if (tid.isEmpty || !await _refreshCart(tid) || cartId.isEmpty) {
      // A refused read is often how the tablet learns the signal is gone.
      if (tid.isNotEmpty && cartId.isNotEmpty && _offlinePrint) {
        final blocked = _offlinePrintBlocked;
        if (blocked == null) return _printBillOffline(tid, paymentMode);
        if (blocked == _offlineCopyTooOld) return blocked;
      }
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

  /// No signal, but the guest is leaving: print the same bill from the cart
  /// this tablet holds, and queue PRINTED for the reconnect.
  /// Works with no server cart at all: a table whose whole order was captured
  /// on this tablet bills from its own lines.
  Future<String?> _printBillOffline(String tid, String? paymentMode) async {
    if (tid.isEmpty || cartMenuItems.isEmpty) return 'No items on this table yet';
    if (hasUnsentKotItems) return 'Send KOT to kitchen before printing the bill';
    final refusal = await _offlineBillRefusal();
    if (refusal != null) return refusal;

    final prefs = await ReceiptPrefs.load();
    final customization = await _receiptCustomization.loadCached();
    final area = await _offlineArea();
    // The same engine the server re-runs at settle, on the lines this tablet
    // holds — never the server's figures, which were priced for a smaller cart.
    final totals = OfflinePricing.compute(
      foodSubtotal: _offlineFoodSubtotal,
      totalQuantity: totalItemCount,
      taxRows: _taxConfig,
      area: area,
      // The cart's own stored charge — the one the server bills from too
      // (helpers/dineinBillTotal.js reads `cartDoc.container_price`; it is
      // never recomputed from the menu). A sitting with no cart yet has none,
      // and the cart this app opens is created with container_price 0, so the
      // paper and the settled order agree at 0.
      containerPrice: containerCharge,
    );
    final number = await _offlineBillNumber();
    try {
      final data = await BillBuilder(_apiService).build(
        tableId: tid,
        tableNumber: tableNumber,
        paymentMode: paymentMode,
        cartSnapshot: _offlineCartDoc(prefs.header),
        taxRows: _taxConfig,
        areas: area == null ? const [] : [TableArea.fromJson(area)],
        totals: totals,
        billNumber: number,
      );
      if (data == null) return 'No active cart found for this table';
      final bytes = await _printer.generateBillBytes(
        bill: data,
        paperSize: prefs.paperSize,
        customization: customization,
        offline: true,
      );
      await _printer.printBytes(bytes, role: PrinterRole.bill);
    } on ApiException catch (e) {
      _sessionExpired = e.isAuth;
      return e.message;
    } catch (e) {
      printError = friendlyError(e);
      debugPrint('[Fatfox POS] Offline bill print error: $e');
      return 'Printer error: ${friendlyError(e)}';
    }
    _lastOfflineTotal = totals.total;
    await _queuePrintStatus('PRINTED', billNumber: number);
    markFloorDirty();
    return null;
  }

  /// The pre-surge food base: every live line's own total, server and draft
  /// alike. Never `menu_total` — the server folds a taxable area surge into
  /// that field (helpers/areaSurge.js), and pricing from it would charge the
  /// surge twice.
  double get _offlineFoodSubtotal => cartMenuItems.fold(
    0.0,
    (sum, m) => sum + _num(m['price'] ?? m['individual_price']),
  );

  /// What the last offline bill put on paper — the amount the settlement
  /// records, and the one checked against the server's own at sync.
  double _lastOfflineTotal = 0;

  /// The cart as this tablet knows it — its own lines, and the restaurant name
  /// from the device's receipt settings (there is no bill header offline).
  /// Money fields are deliberately absent: [OfflinePricing] supplies them.
  Map<String, dynamic> _offlineCartDoc(String restaurantName) => {
    ...?cart,
    if (restaurantName.isNotEmpty) 'restaurant_name': restaurantName,
    'cartMenuData': cartMenuItems,
    'area_id': cart?['area_id'] ?? _activeAreaId,
  };

  /// This table's provisional bill number, minted once and reused by a
  /// reprint (the draft keeps it until the settlement syncs).
  Future<String?> _offlineBillNumber() async {
    if (_restaurantId.isEmpty) return null;
    final existing = _openDraft?.billNumber;
    if (existing != null && existing.isNotEmpty) return existing;
    return OfflineBillNumbers.next(_restaurantId);
  }

  static const String _offlineBillNotPriceable =
      'Send these items when back online before printing the bill.';
  static const String _offlineBillDiscounted =
      'A discount or coupon is on this bill. Only the server can price it — '
      'print and settle it when back online.';
  static const String _offlineBillSplit =
      'Part of this bill is split. Print and settle it when back online.';

  /// Offline the tablet prices the bill itself, so it may print only what it
  /// can price and must not decide. A cart-level discount or coupon is the
  /// server's to revalidate (it can drop it), a split may already be part
  /// paid, and cached tax/area rows too old to trust are no basis for money.
  /// Surge and compounded tax are computable now, so they are not refusals.
  Future<String?> _offlineBillRefusal() async {
    final snapshot = cart ?? const <String, dynamic>{};
    if (discountAmount > 0 || (discountName?.isNotEmpty ?? false)) {
      return _offlineBillDiscounted;
    }
    if (_hasSplit(snapshot)) return _offlineBillSplit;
    if (!_freshEnough(_menuCachedAt)) return _offlineBillNotPriceable;
    // No area row (or one too old) means the surge cannot be priced at all.
    if (await _offlineArea() == null) return _offlineBillNotPriceable;
    return null;
  }

  /// The open table's area row from the cached floor, or null when the FLOOR
  /// itself cannot be trusted (missing, or older than the cache rule) — that
  /// is the only case where the surge is unknown.
  ///
  /// A fresh floor with no row for this table answers with the no-op surge:
  /// restaurants that configure no areas at all, and tables whose area was
  /// deleted, charge nothing — refusing them would make offline billing
  /// impossible for a whole tenant.
  Future<Map<String, dynamic>?> _offlineArea() async {
    final floor = await _drafts.loadFloor(_restaurantId);
    if (floor == null || !_freshEnough(floor.at)) return null;
    final areaId = cart?['area_id']?.toString() ?? _activeAreaId ?? '';
    for (final a in floor.areas) {
      if (a['_id']?.toString() == areaId) return a;
    }
    return const <String, dynamic>{};
  }

  /// Young enough to be trusted; no timestamp at all counts as stale.
  /// [maxAge] defaults to the menu/tax/area cache rule.
  static bool _freshEnough(
    DateTime? at, {
    Duration maxAge = MenuCacheService.defaultMaxAge,
  }) {
    if (at == null) return false;
    final age = DateTime.now().difference(at);
    return !age.isNegative && age < maxAge;
  }

  /// Any split-bill field at all: a share may already be paid, and only the
  /// server knows what is left to charge.
  static bool _hasSplit(Map<String, dynamic> cart) => cart.entries.any(
    (e) => e.key.toLowerCase().contains('split') && _isSet(e.value),
  );

  static bool _isSet(Object? v) => switch (v) {
    null || false => false,
    num n => n != 0,
    String s => s.isNotEmpty && s != '0' && s.toLowerCase() != 'false',
    List l => l.isNotEmpty,
    Map m => m.isNotEmpty,
    _ => true,
  };

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
    if (_offlinePrint) {
      return _settleOffline(ApiService.normalizePaymentType(paymentType));
    }
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

  /// No signal, and the guest is paying: hand them the bill, record the
  /// settlement on this tablet and free the table here. The sale reaches the
  /// server on the reconnect ([_syncSettlementsFor]) carrying `captured_at`,
  /// which is what puts the revenue on the day it was actually taken.
  ///
  /// The settlement TAKES the sitting with it — the table's draft moves onto
  /// the row and the table starts empty — so the next party is billed as its
  /// own order, and a table can be settled as many times as it turns over.
  ///
  /// Refused for everything the tablet must not decide — the same rules as the
  /// bill itself ([_offlineBillRefusal]) — and for a draft that is held.
  Future<bool> _settleOffline(String mode) async {
    final tid = resolvedTableId;
    if (tid.isEmpty || _restaurantId.isEmpty || cartMenuItems.isEmpty) {
      return _sayNo('No items on this table yet');
    }
    final held = _openDraft;
    if (held != null && held.conflict) {
      return _sayNo(
        held.lastError ?? 'Unsent items on this table need attention.',
      );
    }
    if (held?.creatingLine != null) {
      // That item opened the order on a send whose answer never came back. It
      // is uploaded when the sitting replays but is NOT on the bill this
      // tablet prices, so settling now would bill less than the order holds.
      return _sayNo(
        'An item on this table is still being sent. Settle it when back online.',
      );
    }
    final blocked = _offlinePrintBlocked;
    if (blocked != null) return _sayNo(blocked);
    if (hasUnsentKotItems) {
      return _sayNo('Send KOT to kitchen before printing the bill');
    }
    final refusal = await _offlineBillRefusal();
    if (refusal != null) return _sayNo(refusal);
    // A sitting already settled left the table empty, so the guard above is
    // what stops the same one being billed twice.

    _isBusy = true;
    _errorMessage = null;
    printError = null;
    notifyListeners();
    try {
      if (!isBillPrinted) {
        final failure = await _printBillOffline(tid, mode);
        if (failure != null) return _sayNo(failure);
      } else if (_lastOfflineTotal <= 0) {
        final area = await _offlineArea();
        final totals = OfflinePricing.compute(
          foodSubtotal: _offlineFoodSubtotal,
          totalQuantity: totalItemCount,
          taxRows: _taxConfig,
          area: area,
          containerPrice: containerCharge,
        );
        _lastOfflineTotal = totals.total;
      }
      // Only after the paper is in the guest's hand: money taken is recorded,
      // and it takes this sitting's unsent items and print statuses with it.
      final sitting = _openDraft;
      await _drafts.saveSettlement(
        OfflineSettlement(
          restaurantId: _restaurantId,
          tableId: tid,
          key: DeviceIdService.randomHex(),
          paymentType: mode,
          printedTotal: _lastOfflineTotal,
          capturedAt: DateTime.now(),
          tableNumber: tableNumber,
          billNumber: sitting?.billNumber,
          cartId: cartId.isEmpty ? null : cartId,
          draft: sitting,
        ),
      );
      // The table is free on the tablet: no server lines, and no draft — the
      // settlement owns those now. The next party starts from nothing.
      _draft = null;
      await _drafts.delete(_restaurantId, tid);
      _cartData = [];
      await _saveSnapshot();
      markFloorDirty();
      return true;
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  bool _sayNo(String why) {
    _errorMessage = why;
    notifyListeners();
    return false;
  }

  /// This table's settlements, oldest sitting first (a busy table can hold
  /// several from one outage).
  Future<List<OfflineSettlement>> settlementsFor(String tableId) =>
      _drafts.settlementsFor(_restaurantId, tableId);

  /// The waiter says this bill was dealt with elsewhere (reconciled at the
  /// till). The row is KEPT — it is money history — but stops asking to be
  /// sent, which also releases the table: a settlement that can never resolve
  /// would otherwise hold every later sitting on it behind itself.
  ///
  /// Only ever called from a confirmation that names the table, the bill and
  /// the amount: it is an assertion about cash, not a dismissal.
  Future<void> acknowledgeSettlement(OfflineSettlement s) async {
    await _drafts.saveSettlement(
      s.copyWith(acknowledged: true, synced: true, clearError: true),
    );
    notifyListeners();
  }

  /// Tables whose settlements are being sent — one at a time per table, so a
  /// foreground flush and the background loop cannot send the same bill twice.
  final Set<String> _settling = {};

  static const String settlementLostCartMessage =
      'A bill settled offline has no open order to settle against — it was '
      'billed or cleared elsewhere. Check the order before billing it again.';

  /// Sends every bill this table settled offline, oldest sitting first. Each
  /// carries its own items: they are put on the order (create cart, upload,
  /// replay the print statuses — all [_flush]'s job, writing back onto the
  /// settlement row) and only THEN is the bill settled. A later sitting waits
  /// behind the one before it, or its items would join that bill.
  /// Returns how many bills it managed to settle.
  Future<int> _syncSettlementsFor(
    String tid, {
    required bool background,
  }) async {
    if (tid.isEmpty || _restaurantId.isEmpty) return 0;
    // Sync off is a deliberate "talk to nobody": a refusal from the request
    // layer must never be written onto a money row as its last error.
    if (!ConnectivityService.instance.isOnline) return 0;
    if (!_settling.add(tid)) return 0;
    var settled = 0;
    try {
      for (final s in await _drafts.settlementsFor(_restaurantId, tid)) {
        if (s.synced) continue;
        // STOP at the oldest row that is not settled. A later sitting replayed
        // over an open cart the earlier one left behind would take that cart
        // for its own, be refused, and lose the items it was billed for.
        // Waiting is always recoverable; skipping ahead is not.
        if (!s.pending || !s.dueNow) break;
        if (!await _syncSettlement(s, background: background)) break;
        settled++;
        if (_stopSendAll || !ConnectivityService.instance.isOnline) break;
      }
    } finally {
      _settling.remove(tid);
    }
    return settled;
  }

  static const String settlementHeldMessage =
      'This bill is waiting on the order that is open on its table now. '
      'Close or clear that order and it will go up.';

  static const String settlementCartGoneMessage =
      'The order this bill was taken for was billed or cleared elsewhere. '
      'Check it before billing this table again.';

  /// Puts ONE settled sitting's items and print statuses on the server.
  ///
  /// Deliberately isolated from the live table machinery: it reads no
  /// `_openDraft`, writes no `_draft`, `_cartData`, `_cartAt` or snapshot, and
  /// redirects nothing global. Its only inputs are [row] and its owned draft;
  /// its only output is [onProgress], which persists the remaining work back
  /// onto the settlement row (null = nothing left) so a crash resumes exactly
  /// where it stopped. That is what keeps a replay from touching the party
  /// sitting at that table right now.
  ///
  /// Same request order as a live send — create the cart, the printed batch,
  /// its statuses, then anything added after the print.
  /// False = not placed: retry later, or wait for the waiter ([lastError]).
  Future<bool> _placeSitting(
    OfflineSettlement row, {
    required bool background,
    required Future<void> Function(TableDraft?, {String? error}) onProgress,
  }) async {
    final tid = row.tableId;
    var d = row.draft!;
    // The live send holds the same per-table lock, so a replay and a send can
    // never interleave requests for one table.
    if (_sending.contains(tid)) return false;
    _sending.add(tid);
    try {
      final live = await _apiService.getCartItemsByTableId(
        tid,
        background: background,
        fresh: true,
      );
      var liveId = _cartIdOf(live);
      // Read before this replay's own writes.
      final liveStatus =
          live.isEmpty ? '' : (live.first['table_status']?.toString() ?? '');

      if (liveId.isEmpty) {
        if (d.baselineCartId != null) {
          // This sitting was captured onto a cart that is gone: it was billed
          // or cleared at the till during the outage. Opening a fresh cart
          // here would make a SECOND order for items already on a bill.
          await _holdSettlement(onProgress, d, why: settlementCartGoneMessage);
          return false;
        }
        final pending = d.creatingLine;
        if (pending != null) {
          // An earlier createcart never answered and there is no order now: it
          // may have reached one that has been billed since. Only the waiter
          // can tell, so it is never re-created automatically.
          await _holdSettlement(onProgress, d);
          return false;
        }
        // The oldest batch opens the order: a printed line if there is one.
        final fromPrinted = d.printedLines.isNotEmpty;
        final first = fromPrinted ? d.printedLines.first : d.lines.first;
        // Persisted before sending, so a lost answer is recognised next time.
        d = d.copyWith(
          creatingLine: first,
          lines: fromPrinted ? d.lines : d.lines.sublist(1),
          printedLines: fromPrinted ? d.printedLines.sublist(1) : d.printedLines,
        );
        await onProgress(d);
        try {
          await _createCartLine(tid, first, background: background);
        } on ApiException catch (e) {
          // A refusal is a definite "not added": put the line back so a later
          // pass can place it. Only a lost answer keeps it locked.
          if (!e.isNetwork) {
            d = d.copyWith(
              clearCreating: true,
              lines: fromPrinted ? d.lines : [first, ...d.lines],
              printedLines:
                  fromPrinted ? [first, ...d.printedLines] : d.printedLines,
            );
            await onProgress(d);
          }
          rethrow;
        }
        liveId = _cartIdOf(
          await _apiService.getCartItemsByTableId(tid, background: background, fresh: true),
        );
        if (liveId.isEmpty) return false; // answered, but no order: try again
        d = d.copyWith(clearCreating: true, baselineCartId: liveId);
        await onProgress(d);
      } else if (d.creatingLine != null) {
        if (!_cartHasLine(live, d.creatingLine!)) {
          await _holdSettlement(onProgress, d);
          return false;
        }
        d = d.copyWith(clearCreating: true, baselineCartId: liveId);
        await onProgress(d);
      } else if (d.baselineCartId != liveId) {
        // An order is open on this table that is not the one this sitting was
        // billed for — the table turned over, or a bill in front of this one
        // has not settled yet. Its items must never join that order.
        await _holdSettlement(onProgress, d);
        return false;
      }

      // Order matters: the printed batch, then its status, then whatever was
      // added after the print (which that status must not touch).
      if (d.printedLines.isNotEmpty) {
        await _apiService.offlineSync(
          tableId: tid,
          idempotencyKey: d.printedKey ?? d.key,
          lines: d.printedLines.map((l) => l.toSyncJson()).toList(),
          capturedAt: d.createdAt,
          background: background,
        );
        d = d.copyWith(printedLines: const []);
        await onProgress(d);
      }

      // A status the order has already moved past is dropped, never forced —
      // the settle below is what this row is really for.
      final movedOn = liveStatus == 'PRINTED' || liveStatus == 'PAID';
      for (final status in TableDraft.opOrder) {
        if (!d.pendingOps.contains(status)) continue;
        if (!movedOn) {
          await _apiService.offlineStatus(
            cartId: d.baselineCartId ?? liveId,
            tableStatus: status,
            idempotencyKey: _statusKey(d, status),
            capturedAt: d.createdAt,
            background: background,
          );
        }
        // One at a time: a refused PRINTED must not make the server re-live a
        // KOT_PRINT it already has.
        d = d.copyWith(pendingOps: [...d.pendingOps]..remove(status));
        await onProgress(d);
      }

      if (d.lines.isNotEmpty) {
        await _apiService.offlineSync(
          tableId: tid,
          idempotencyKey: d.key,
          lines: d.lines.map((l) => l.toSyncJson()).toList(),
          capturedAt: d.createdAt,
          background: background,
        );
        d = d.copyWith(lines: const []);
      }
      // Everything is on the order; the row keeps only the bill from here.
      await onProgress(null);
      return true;
    } on ApiException catch (e) {
      if (e.isAuth) {
        _sessionExpired = true;
        _stopSendAll = true;
      }
      if (e.isNetwork || e.isSubscriptionLocked || e.code >= 500 ||
          e.code == 408 || e.code == 429) {
        return false; // worth retrying, and nothing to tell the waiter yet
      }
      await _holdSettlement(onProgress, d, why: e.message);
      return false;
    } catch (e) {
      debugPrint('[Fatfox POS] settlement replay error: $e');
      return false;
    } finally {
      _sending.remove(tid);
    }
  }

  /// The sitting cannot be placed by the tablet alone. The row keeps every
  /// item it still owes (nothing is cleared) and says why.
  Future<void> _holdSettlement(
    Future<void> Function(TableDraft?, {String? error}) onProgress,
    TableDraft d, {
    String? why,
  }) async => onProgress(d, error: why ?? settlementHeldMessage);

  /// Puts one settlement's sitting on the server and bills it. False when the
  /// next settlement on this table must wait (its order is not complete).
  ///
  /// 200 applied / 200 duplicate both mark the row synced (a duplicate is the
  /// answer to a lost response, never a second bill). 409 is terminal and is
  /// said out loud. Everything else waits for the next pass.
  Future<bool> _syncSettlement(
    OfflineSettlement s, {
    bool background = false,
  }) async {
    final rid = _restaurantId;
    final tid = s.tableId;
    var row = s;

    // The sitting's own items and statuses, put on the server by the ISOLATED
    // replay: it reads and writes nothing but this settlement row.
    final owned = row.draft;
    if (owned != null && !owned.isEmpty) {
      final placed = await _placeSitting(
        row,
        background: background,
        onProgress: (d, {String? error}) async {
          row = row.copyWith(
            draft: d,
            clearDraft: d == null,
            lastError: error,
            clearError: error == null,
            // A hold is a failed attempt like any other: without the backoff
            // every pass would re-run the whole replay for a bill that cannot
            // move, and the C1 rule would hold every later sitting behind it.
            attempts: error == null ? null : row.attempts + 1,
            lastTriedAt: error == null ? null : DateTime.now(),
          );
          await _drafts.saveSettlement(row);
        },
      );
      // Held, refused or unreachable: an order billed short is worse than one
      // billed late, so this settlement and every later one wait.
      if (!placed) {
        if (row.lastError != null && !background) {
          _errorMessage = row.lastError;
          notifyListeners();
        }
        return false;
      }
    }

    try {
      // Re-read EVERY attempt: between attempts the sitting may have been
      // billed at the till, and a stale id would post against a dead cart.
      var cid = _cartIdOf(
        await _apiService.getCartItemsByTableId(tid, background: background, fresh: true),
      );
      if (cid.isEmpty) {
        // Nothing open. If this row was never sent there is nothing the server
        // could answer for it — terminal, and said out loud. If it WAS sent,
        // the cart may be gone because that send worked, so the same key is
        // posted once more to collect the duplicate answer.
        if (row.cartId == null) {
          await _failSettlement(
            row.copyWith(conflict: true, lastError: settlementLostCartMessage),
            background,
          );
          return false;
        }
        cid = row.cartId!;
      }
      if (row.cartId != cid) {
        // Stored before the send, so a lost answer retries the same order.
        row = row.copyWith(cartId: cid);
        await _drafts.saveSettlement(row);
      }

      final env = await _apiService.offlineSettle(
        cartId: cid,
        paymentType: row.paymentType,
        idempotencyKey: row.key,
        capturedAt: row.capturedAt,
        background: background,
      );
      final data = env.map ?? const <String, dynamic>{};
      final serverTotal = _num(
        data['total_price'] ?? data['total'] ?? data['order_total'],
      );
      await OfflineBillNumbers.remember(rid, data['order_no']);
      final settled = row.copyWith(
        synced: true,
        clearError: true,
        orderId: data['order_id']?.toString(),
        orderNo: data['order_no']?.toString(),
        serverTotal: serverTotal > 0 ? serverTotal : null,
      );
      await _drafts.saveSettlement(settled);
      if (settled.mismatched && !background) {
        _errorMessage = totalMismatchMessage(settled);
        notifyListeners();
      }
      return true;
    } on ApiException catch (e) {
      if (e.isAuth) {
        _sessionExpired = true;
        _stopSendAll = true;
      }
      // 409: the server has already answered this key with something else.
      // Retrying cannot change that, and a second bill must never be made.
      await _failSettlement(
        row.copyWith(
          conflict: e.code == 409,
          // A lost signal is the ordinary offline case, not something the
          // waiter must act on: it leaves no reason on the row, so the row
          // stays "waiting for the next sync" rather than "needs attention".
          clearError: e.isNetwork,
          lastError: e.code == 409
              ? 'The server refused this offline settlement (conflict). '
                  'Check the order before billing it again.'
              : (e.isNetwork ? null : e.message),
          // A lost signal is not the settlement's fault: no backoff, the next
          // pass (the connectivity probe drives it) tries again straight away.
          attempts: e.isNetwork ? row.attempts : row.attempts + 1,
          lastTriedAt: DateTime.now(),
        ),
        background,
      );
      return false;
    }
  }

  Future<void> _failSettlement(OfflineSettlement s, bool background) async {
    await _drafts.saveSettlement(s);
    if (s.conflict && !background) {
      _errorMessage = s.lastError;
      notifyListeners();
    }
  }

  /// The server re-prices at settle and ignores the printed total, so a
  /// difference is the waiter's to reconcile with the guest.
  static String totalMismatchMessage(OfflineSettlement s) =>
      'Bill ${s.billNumber ?? ''} printed ₹${s.printedTotal.toStringAsFixed(2)} '
      'but the server billed ₹${(s.serverTotal ?? 0).toStringAsFixed(2)}. '
      'The order is correct; the paper is not.';

  void clearCart() {
    _cartData = [];
    notifyListeners();
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }
}
