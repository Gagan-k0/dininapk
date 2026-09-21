import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../providers/pos_provider.dart';
import '../../services/auth_service.dart';
import '../../services/csv_export_service.dart';

/// Transaction report screen — fetches settled orders from the server AND
/// offline settlements from the draft store, showing summary cards and an
/// order list, and lets the user download a CSV.
class TransactionReportScreen extends StatefulWidget {
  final PosProvider posProvider;

  const TransactionReportScreen({super.key, required this.posProvider});

  @override
  State<TransactionReportScreen> createState() =>
      _TransactionReportScreenState();
}

class _TransactionReportScreenState extends State<TransactionReportScreen> {
  // ── state ───────────────────────────────────────────────────
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;
  bool _exporting = false;

  // Date filter — defaults to today.
  late DateTime _from;
  late DateTime _to;
  String _rangeLabel = 'Today';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, now.day);
    _to = DateTime(now.year, now.month, now.day, 23, 59, 59);
    _fetchOrders();
  }

  // ── data ────────────────────────────────────────────────────

  Future<void> _fetchOrders() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fmt = DateFormat('yyyy-MM-dd');
      final onlineOrders = await widget.posProvider.apiService.getOrders(
        from: fmt.format(_from),
        to: fmt.format(_to),
      );
      
      // Fetch offline settlements and convert them into the identical map schema
      // so they merge seamlessly into the UI and the CSV export.
      final auth = AuthService();
      final rid = await auth.getRestaurantId();
      final List<Map<String, dynamic>> allOrders = List.from(onlineOrders);
      
      if (rid != null) {
        final offlineSettlements = await widget.posProvider.drafts.allSettlements(rid);
        // Filter by date range (from _from to _to inclusive)
        final fromStart = DateTime(_from.year, _from.month, _from.day);
        final toEnd = DateTime(_to.year, _to.month, _to.day, 23, 59, 59);

        for (final settlement in offlineSettlements) {
          if (settlement.capturedAt.isBefore(fromStart) ||
              settlement.capturedAt.isAfter(toEnd)) {
            continue;
          }
          
          final draft = settlement.draft;
          final lines = <Map<String, dynamic>>[];
          if (draft != null) {
            lines.addAll(draft.printedLines.map((l) => l.toCartLineMap(printed: true)));
            lines.addAll(draft.unprintedLines.map((l) => l.toCartLineMap(printed: false)));
          }

          allOrders.add({
            'createdAt': settlement.capturedAt.toIso8601String(),
            'order_no': settlement.billNumber ?? settlement.orderNo ?? '',
            'table_number': settlement.tableNumber,
            'food_subtotal': draft?.subtotal ?? 0.0,
            'tax_price': (settlement.printedTotal) - (draft?.subtotal ?? 0.0),
            'discount_price': 0.0,
            'total_price': settlement.printedTotal,
            'payment_type': settlement.paymentType,
            'cartMenuData': lines,
            '_isOffline': true,
          });
        }
      }

      // Sort combined orders by date descending
      allOrders.sort((a, b) {
        final da = DateTime.tryParse(a['createdAt'] ?? a['created_at'] ?? '') ?? DateTime.now();
        final db = DateTime.tryParse(b['createdAt'] ?? b['created_at'] ?? '') ?? DateTime.now();
        return db.compareTo(da);
      });

      if (!mounted) return;
      setState(() {
        _orders = allOrders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  // ── CSV export ──────────────────────────────────────────────

  Future<void> _exportCsv() async {
    if (_orders.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No orders to export')),
      );
      return;
    }
    setState(() => _exporting = true);
    try {
      final csv = CsvExportService.buildCsv(_orders);
      final file = await CsvExportService.saveCsv(csv);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('CSV saved to ${_shortPath(file)}'),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: 'OK',
            onPressed: () {},
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  static String _shortPath(File f) {
    final p = f.path;
    final idx = p.indexOf('Download');
    return idx >= 0 ? p.substring(idx) : p;
  }

  // ── date range presets ──────────────────────────────────────

  void _setRange(String label, DateTime from, DateTime to) {
    setState(() {
      _rangeLabel = label;
      _from = from;
      _to = to;
    });
    _fetchOrders();
  }

  void _today() {
    final now = DateTime.now();
    _setRange(
      'Today',
      DateTime(now.year, now.month, now.day),
      DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  void _yesterday() {
    final now = DateTime.now();
    final y = now.subtract(const Duration(days: 1));
    _setRange(
      'Yesterday',
      DateTime(y.year, y.month, y.day),
      DateTime(y.year, y.month, y.day, 23, 59, 59),
    );
  }

  void _last7Days() {
    final now = DateTime.now();
    final from = now.subtract(const Duration(days: 6));
    _setRange(
      'Last 7 Days',
      DateTime(from.year, from.month, from.day),
      DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  Future<void> _pickCustomRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: Theme.of(ctx).colorScheme.copyWith(
                primary: const Color(0xFFE65100),
              ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      _setRange(
        '${DateFormat('dd MMM').format(picked.start)} – ${DateFormat('dd MMM').format(picked.end)}',
        picked.start,
        DateTime(picked.end.year, picked.end.month, picked.end.day, 23, 59, 59),
      );
    }
  }

  // ── summary computation ─────────────────────────────────────

  int get _totalOrders => _orders.length;

  double get _totalRevenue {
    var sum = 0.0;
    for (final o in _orders) {
      sum += _num(o['total_price']);
    }
    return sum;
  }

  double get _avgOrder => _totalOrders > 0 ? _totalRevenue / _totalOrders : 0;

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }

  // ── build ───────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text('Transaction Report'),
        backgroundColor: const Color(0xFF1A2332),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_exporting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'Download CSV',
              onPressed: _exportCsv,
            ),
        ],
      ),
      body: Column(
        children: [
          // Date filter chips
          _buildDateBar(),
          // Summary cards
          _buildSummaryCards(),
          // Order list
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildDateBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _chip('Today', _rangeLabel == 'Today', _today),
          const SizedBox(width: 8),
          _chip('Yesterday', _rangeLabel == 'Yesterday', _yesterday),
          const SizedBox(width: 8),
          _chip('Last 7 Days', _rangeLabel == 'Last 7 Days', _last7Days),
          const SizedBox(width: 8),
          _chip('Custom…', _rangeLabel.contains('–'), _pickCustomRange),
          const Spacer(),
          Text(
            _rangeLabel,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFE65100) : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.grey.shade800,
            fontWeight: FontWeight.w500,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCards() {
    final moneyFmt = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        children: [
          _summaryCard(
            'Orders',
            _totalOrders.toString(),
            Icons.receipt_long_rounded,
            const Color(0xFF2196F3),
          ),
          const SizedBox(width: 12),
          _summaryCard(
            'Revenue',
            moneyFmt.format(_totalRevenue),
            Icons.currency_rupee_rounded,
            const Color(0xFF4CAF50),
          ),
          const SizedBox(width: 12),
          _summaryCard(
            'Avg Order',
            moneyFmt.format(_avgOrder),
            Icons.trending_up_rounded,
            const Color(0xFFFF9800),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(
      String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color.withOpacity(0.9),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFE65100)),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _fetchOrders,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long, size: 56, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text(
              'No transactions found',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Try a different date range',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade400,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _orders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (ctx, i) => _orderTile(_orders[i]),
    );
  }

  Widget _orderTile(Map<String, dynamic> o) {
    final dt = DateTime.tryParse(
        (o['createdAt'] ?? o['created_at'] ?? '').toString());
    final time = dt != null ? DateFormat('HH:mm').format(dt) : '';
    final table =
        (o['table_number'] ?? o['table_no'] ?? o['table_name'] ?? '')
            .toString();
    final total = _num(o['total_price']);
    final payment =
        (o['payment_type'] ?? o['paymentType'] ?? '').toString().toUpperCase();
    final billNo =
        (o['order_no'] ?? o['orderNo'] ?? o['_id'] ?? '').toString();
    final itemCount = _countItems(o);

    Color payColor;
    switch (payment) {
      case 'CASH':
        payColor = const Color(0xFF4CAF50);
        break;
      case 'CARD':
        payColor = const Color(0xFF2196F3);
        break;
      case 'ONLINE':
      case 'UPI':
        payColor = const Color(0xFF9C27B0);
        break;
      default:
        payColor = Colors.grey;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Table badge
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFE65100).withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(
              table.isNotEmpty ? table : '–',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFFE65100),
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 14),
          // Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      billNo.length > 12 ? billNo.substring(billNo.length - 8) : billNo,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    if (o['_isOffline'] == true) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.cloud_off, size: 14, color: Colors.orange),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '$time  •  $itemCount item${itemCount != 1 ? 's' : ''}',
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          // Total
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '₹${total.toStringAsFixed(total.truncateToDouble() == total ? 0 : 2)}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: payColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  payment,
                  style: TextStyle(
                    color: payColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int _countItems(Map<String, dynamic> o) {
    final raw = o['cartMenuData'] ?? o['orderMenuData'];
    if (raw is! List) return 0;
    var count = 0;
    for (final m in raw) {
      if (m is! Map) continue;
      if (m['cancel_status'] == 1 || m['cancel_status'] == '1') continue;
      count += int.tryParse(m['quantity']?.toString() ?? '1') ?? 1;
    }
    return count;
  }
}
