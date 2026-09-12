import 'package:flutter/foundation.dart';
import '../models/table_model.dart';
import '../services/api_service.dart';

class TableProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();

  List<TableArea> _areas = [];
  List<DineInTable> _tables = [];
  List<Map<String, dynamic>> _reservations = [];
  List<Map<String, dynamic>> _liveOrders = [];

  int _selectedTab = 0; // 0: Dine In Tables, 1: Pre Booking Dine In, 2: Live Orders
  String? _selectedAreaId; // null = 'ALL'
  String _selectedStatusFilter = 'ALL'; // 'ALL', 'AVAILABLE', 'OCCUPIED', 'KOT'
  String _searchQuery = '';
  bool _isLoading = false;
  String? _errorMessage;

  List<TableArea> get areas => _areas;
  List<DineInTable> get tables => _tables;
  List<Map<String, dynamic>> get reservations => _reservations;
  List<Map<String, dynamic>> get liveOrders => _liveOrders;

  int get selectedTab => _selectedTab;
  String? get selectedAreaId => _selectedAreaId;
  String get selectedStatusFilter => _selectedStatusFilter;
  String get searchQuery => _searchQuery;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  // 100% Dynamic KPI Metrics calculated live from backend REST API
  int get totalTablesCount => _tables.length;
  int get availableTablesCount => _tables.where((t) => t.isAvailable).length;
  int get occupiedTablesCount => _tables.where((t) => t.isOccupied).length;
  int get kotTablesCount => _tables.where((t) => t.isKot).length;

  List<DineInTable> get filteredTables {
    var result = List<DineInTable>.from(_tables);

    // Apply Area Filter
    if (_selectedAreaId != null && _selectedAreaId!.isNotEmpty) {
      result = result.where((t) => t.areaId == _selectedAreaId).toList();
    }

    // Apply Status Filter
    if (_selectedStatusFilter != 'ALL') {
      if (_selectedStatusFilter == 'AVAILABLE') {
        result = result.where((t) => t.isAvailable).toList();
      } else if (_selectedStatusFilter == 'OCCUPIED') {
        result = result.where((t) => t.isOccupied).toList();
      } else if (_selectedStatusFilter == 'KOT') {
        result = result.where((t) => t.isKot).toList();
      }
    }

    // Apply Search Filter
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase().trim();
      result = result.where((t) => t.tableNumber.toLowerCase().contains(q)).toList();
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

  Future<void> loadDashboardData() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final areaList = await _apiService.getAreas();
      final tableList = await _apiService.getTables();
      final resList = await _apiService.getReservations();
      final orderList = await _apiService.getLiveOrders();

      debugPrint('[Fatfox TableProvider] Dynamic Live API Fetch: ${areaList.length} areas, ${tableList.length} tables, ${resList.length} reservations, ${orderList.length} live orders');

      _areas = areaList;
      _tables = tableList;
      _reservations = resList;
      _liveOrders = orderList;
    } catch (e) {
      debugPrint('[Fatfox TableProvider] Live fetch error: $e');
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> releaseTable(String tableId) async {
    try {
      final success = await _apiService.releaseTable(tableId);
      if (success) {
        await loadDashboardData();
        return true;
      }
    } catch (e) {
      _errorMessage = e.toString();
    }
    return false;
  }

  /// Move an active cart to another blank/available table.
  Future<bool> shiftTable({
    required String cartId,
    required String newTableId,
  }) async {
    try {
      final result = await _apiService.switchTable(
        cartId: cartId,
        tableId: newTableId,
      );
      final statusCode = result['status']?['code'];
      final ok = statusCode == 200 || (statusCode == null && result.isNotEmpty);
      if (ok) {
        _errorMessage = null;
        await loadDashboardData();
        return true;
      }
      _errorMessage =
          result['status']?['message']?.toString() ?? 'Failed to shift table';
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }
    notifyListeners();
    return false;
  }

  /// Accept or reject a QR dine-in order waiting for staff approval.
  Future<bool> decideQrOrder({
    required String cartId,
    required String action,
  }) async {
    try {
      final result = await _apiService.decideQrOrder(
        cartId: cartId,
        action: action,
      );
      final statusCode = result['status']?['code'];
      final ok = statusCode == 200 || (statusCode == null && result.isNotEmpty);
      if (ok) {
        _errorMessage = null;
        await loadDashboardData();
        return true;
      }
      _errorMessage = result['status']?['message']?.toString() ??
          'Failed to ${action.toLowerCase()} QR order';
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
    }
    notifyListeners();
    return false;
  }
}
