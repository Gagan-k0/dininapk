import 'package:flutter/foundation.dart';

import '../models/table_model.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';

/// Floor state. Mirrors the admin `dinein-table-list` contract:
/// * areas + tables are the floor (mandatory); reservations + live orders are
///   best-effort feeds that must never blank the grid;
/// * on a failed refresh the last-known-good floor stays on screen and is
///   flagged stale (never an empty grid);
/// * a refused action surfaces the SERVER's message — the envelope decides,
///   not the transport.
class TableProvider with ChangeNotifier {
  final ApiService _apiService;
  final AuthService _authService;

  TableProvider({ApiService? api, AuthService? auth})
      : _apiService = api ?? ApiService(),
        _authService = auth ?? AuthService();

  List<TableArea> _areas = [];
  List<DineInTable> _tables = [];
  List<Map<String, dynamic>> _reservations = [];
  List<Map<String, dynamic>> _liveOrders = [];

  int _selectedTab =
      0; // 0: Dine In Tables, 1: Pre Booking Dine In, 2: Live Orders
  String? _selectedAreaId; // null = 'ALL'
  String _selectedStatusFilter = 'ALL'; // 'ALL', 'AVAILABLE', 'OCCUPIED', 'KOT'
  String _searchQuery = '';
  bool _isLoading = false; // first load / explicit reload with spinner
  bool _isRefreshing = false; // background refresh, grid stays visible
  bool _sessionExpired = false;
  String? _errorMessage;
  DateTime? _lastSyncedAt;
  String? _syncedRestaurantId;
  /// Bumped in [reset] so in-flight [_load] results are discarded.
  int _loadEpoch = 0;

  static const Duration floorTtl = Duration(seconds: 45);

  List<TableArea> get areas => _areas;
  List<DineInTable> get tables => _tables;
  List<Map<String, dynamic>> get reservations => _reservations;
  List<Map<String, dynamic>> get liveOrders => _liveOrders;

  int get selectedTab => _selectedTab;
  String? get selectedAreaId => _selectedAreaId;
  String get selectedStatusFilter => _selectedStatusFilter;
  String get searchQuery => _searchQuery;
  bool get isLoading => _isLoading;
  bool get isRefreshing => _isRefreshing;
  bool get sessionExpired => _sessionExpired;
  String? get errorMessage => _errorMessage;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// True when the floor on screen could not be refreshed on the last attempt.
  bool get isStale => _errorMessage != null && _lastSyncedAt != null;
  bool get hasFloor => _areas.isNotEmpty || _tables.isNotEmpty;

  String get lastSyncedLabel {
    final t = _lastSyncedAt;
    if (t == null) return '';
    final m = DateTime.now().difference(t).inMinutes;
    if (m < 1) return 'just now';
    if (m == 1) return '1 minute ago';
    if (m < 60) return '$m minutes ago';
    final h = m ~/ 60;
    return h == 1 ? '1 hour ago' : '$h hours ago';
  }

  // KPI counters over the UNFILTERED floor (admin computes them the same way).
  int get totalTablesCount => _tables.length;
  int get availableTablesCount => _tables.where((t) => t.isAvailable).length;
  int get occupiedTablesCount => _tables.where((t) => t.isOccupied).length;
  int get kotTablesCount => _tables.where((t) => t.isKot).length;

  List<DineInTable> get filteredTables {
    var result = List<DineInTable>.from(_tables);

    if (_selectedAreaId != null && _selectedAreaId!.isNotEmpty) {
      result = result.where((t) => t.areaId == _selectedAreaId).toList();
    }

    switch (_selectedStatusFilter) {
      case 'AVAILABLE':
        result = result.where((t) => t.isAvailable).toList();
        break;
      case 'OCCUPIED':
        // Admin: occupied AND not KOT/KOT_PRINT (those live under the KOT tile).
        result = result.where((t) => t.isOccupied && !t.isKot).toList();
        break;
      case 'KOT':
        result = result.where((t) => t.isKot).toList();
        break;
    }

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase().trim();
      result = result.where((t) {
        return t.tableNumber.toLowerCase().contains(q) ||
            (t.customerName?.toLowerCase().contains(q) ?? false) ||
            t.dineinType.toLowerCase().contains(q);
      }).toList();
    }

    return result;
  }

  void setSelectedTab(int index) {
    _selectedTab = index;
    notifyListeners();
  }

  void selectArea(String? areaId) {
    _selectedAreaId = areaId;
    notifyListeners();
  }

  void setStatusFilter(String filter) {
    _selectedStatusFilter = filter;
    notifyListeners();
  }

  void setSearchQuery(String q) {
    _searchQuery = q;
    notifyListeners();
  }

  /// Clears everything on logout so the next login never paints another
  /// restaurant's floor.
  void reset() {
    _loadEpoch++;
    _areas = [];
    _tables = [];
    _reservations = [];
    _liveOrders = [];
    _errorMessage = null;
    _lastSyncedAt = null;
    _syncedRestaurantId = null;
    _sessionExpired = false;
    _isLoading = false;
    _isRefreshing = false;
    _selectedAreaId = null;
    _selectedStatusFilter = 'ALL';
    _searchQuery = '';
    _selectedTab = 0;
    notifyListeners();
  }

  bool _isFresh(Duration ttl) {
    final t = _lastSyncedAt;
    if (t == null) return false;
    return DateTime.now().difference(t) < ttl;
  }

  /// Skip network when the in-memory floor is healthy and recent for this restaurant.
  Future<void> ensureLoaded({Duration ttl = floorTtl}) async {
    final rid = await _authService.getRestaurantId();
    if (hasFloor &&
        !isStale &&
        !_sessionExpired &&
        _isFresh(ttl) &&
        rid != null &&
        rid.isNotEmpty &&
        rid == _syncedRestaurantId) {
      return;
    }
    await _load(background: hasFloor);
  }

  /// Initial / explicit load (spinner only while there is nothing to show).
  Future<void> loadDashboardData() => _load(background: false);

  /// Background refresh: keeps the grid visible, flags stale on failure.
  Future<void> refresh() => _load(background: true);

  Future<void> _load({required bool background}) async {
    if (_isLoading || _isRefreshing) return;
    final epoch = _loadEpoch;
    final expectedRid = await _authService.getRestaurantId();
    if (epoch != _loadEpoch) return;

    if (background) {
      _isRefreshing = true;
    } else {
      _isLoading = !hasFloor; // spinner only for a truly empty screen
      _isRefreshing = hasFloor;
    }
    _errorMessage = null;
    notifyListeners();

    try {
      // Floor (mandatory) — areas and tables in parallel.
      final results = await Future.wait<Object>([
        _apiService.getAreas(),
        _apiService.getTables(),
      ]);
      if (epoch != _loadEpoch) return;

      final rid = await _authService.getRestaurantId();
      if (epoch != _loadEpoch || rid != expectedRid) return;

      _areas = results[0] as List<TableArea>;
      _tables = results[1] as List<DineInTable>;
      _lastSyncedAt = DateTime.now();
      _syncedRestaurantId = rid;
      _sessionExpired = false;

      // Best-effort feeds — a failure here must not touch the floor.
      _reservations = await _bestEffort(
        _apiService.getReservations,
        _reservations,
      );
      if (epoch != _loadEpoch) return;
      _liveOrders = await _bestEffort(_apiService.getLiveOrders, _liveOrders);
      if (epoch != _loadEpoch) return;

      debugPrint(
        '[Fatfox TableProvider] ${_areas.length} areas, ${_tables.length} tables, '
        '${_reservations.length} reservations, ${_liveOrders.length} live orders',
      );
    } on ApiException catch (e) {
      if (epoch != _loadEpoch) return;
      debugPrint('[Fatfox TableProvider] floor load refused: $e');
      _errorMessage = e.message;
      _sessionExpired = e.isAuth;
    } catch (e) {
      if (epoch != _loadEpoch) return;
      debugPrint('[Fatfox TableProvider] floor load error: $e');
      _errorMessage = friendlyError(e);
    } finally {
      if (epoch == _loadEpoch) {
        _isLoading = false;
        _isRefreshing = false;
        notifyListeners();
      }
    }
  }

  Future<List<Map<String, dynamic>>> _bestEffort(
    Future<List<Map<String, dynamic>>> Function() fetch,
    List<Map<String, dynamic>> previous,
  ) async {
    try {
      return await fetch();
    } on ApiException catch (e) {
      if (e.isAuth) rethrow;
      debugPrint('[Fatfox TableProvider] feed failed (kept previous): $e');
      return previous;
    } catch (e) {
      debugPrint('[Fatfox TableProvider] feed error (kept previous): $e');
      return previous;
    }
  }

  DineInTable? tableById(String id) {
    for (final t in _tables) {
      if (t.id == id) return t;
    }
    return null;
  }

  bool _mutating = false;

  /// Runs a mutating action; on success reloads the floor, on refusal stores
  /// the SERVER message and returns false. Returns `null` if already mutating
  /// (silent skip — callers must not toast that as failure).
  Future<bool?> _mutate(Future<void> Function() action) async {
    if (_mutating) return null;
    _mutating = true;
    try {
      await action();
      _errorMessage = null;
      await refresh();
      return true;
    } on ApiException catch (e) {
      _errorMessage = e.message;
      _sessionExpired = e.isAuth;
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = friendlyError(e);
      notifyListeners();
      return false;
    } finally {
      _mutating = false;
    }
  }

  /// SETTLE — admin "Release Table": POST setcarttobill { cartId, paymentType }.
  /// Creates the Order + ledger row and frees the table. Never deletecart.
  Future<bool?> settleTable({
    required String cartId,
    required String paymentType,
  }) =>
      _mutate(
        () => _apiService.settleBill(cartId: cartId, paymentType: paymentType),
      );

  /// Move an active cart to another blank/available table.
  Future<bool?> shiftTable({
    required String cartId,
    required String newTableId,
  }) =>
      _mutate(
        () => _apiService.switchTable(cartId: cartId, tableId: newTableId),
      );

  /// Accept or reject a QR dine-in order waiting for staff approval.
  Future<bool?> decideQrOrder({
    required String cartId,
    required String action,
  }) =>
      _mutate(() => _apiService.decideQrOrder(cartId: cartId, action: action));
}
