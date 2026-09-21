import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../providers/pos_provider.dart';
import '../../services/auth_service.dart';
import '../../services/csv_export_service.dart';
import '../../services/draft_cart_store.dart';
import 'csv_preview_screen.dart';

/// Transaction report screen — fetches settled orders from the server AND
/// offline settlements from the draft store, showing summary cards and an
/// order list, and lets the user download a CSV.
class TransactionReportScreen extends StatefulWidget {
  final PosProvider posProvider;

  const TransactionReportScreen({super.key, required this.posProvider});

  @override
  State<TransactionReportScreen> createState() =>
      _TransactionReportScreenState();

  /// [online] is null when the server could not be reached. It may span more
  /// than [from]..[to] (the server's day filter is UTC), so it is trimmed to
  /// the local range here, like the offline bills. A synced offline bill is
  /// hidden only when its server order is actually in the list.
  @visibleForTesting
  static List<Map<String, dynamic>> mergeOrders({
    required List<Map<String, dynamic>>? online,
    required List<OfflineSettlement> settlements,
    required DateTime from,
    required DateTime to,
  }) {
    bool inRange(DateTime t) => !t.isBefore(from) && !t.isAfter(to);
    final kept = [
      for (final o in online ?? const <Map<String, dynamic>>[])
        if (inRange(_dateOf(o).toLocal())) o,
    ];
    final ids = <String>{
      for (final o in kept) ...[
        if (o['_id'] != null) o['_id'].toString(),
        if (o['order_no'] != null) o['order_no'].toString(),
      ],
    };
    final all = <Map<String, dynamic>>[...kept];
    for (final s in settlements) {
      if (!inRange(s.capturedAt)) continue;
      final onServer = s.synced &&
          (ids.contains(s.orderId) || ids.contains(s.orderNo));
      if (!onServer) all.add(offlineRow(s));
    }
    all.sort((a, b) => _dateOf(b).compareTo(_dateOf(a)));
    return all;
  }

  static DateTime _dateOf(Map<String, dynamic> o) =>
      DateTime.tryParse((o['createdAt'] ?? o['created_at'] ?? '').toString()) ??
      DateTime.fromMillisecondsSinceEpoch(0);

  /// An offline settlement in the `GET /restaurant/order` row shape.
  ///
  /// Its draft holds only the items the server had not received, and the
  /// sync drains it, so the lines are the whole bill only while the sitting
  /// never had a server cart and was never tried. Otherwise subtotal is left
  /// unset rather than guessed. Tax is never derived: the printed total also
  /// carries container charges and round-off.
  @visibleForTesting
  static Map<String, dynamic> offlineRow(OfflineSettlement s) {
    final draft = s.draft;
    final complete = draft != null &&
        !s.synced &&
        s.cartId == null &&
        s.lastTriedAt == null;
    final lines = [
      for (final l in draft?.printedLines ?? const <DraftLine>[])
        l.toCartLineMap(printed: true),
      for (final l in draft?.unprintedLines ?? const <DraftLine>[])
        l.toCartLineMap(),
    ];
    return {
      'createdAt': s.capturedAt.toIso8601String(),
      'order_no': s.billNumber ?? s.orderNo ?? '',
      'table_number': s.tableNumber,
      if (complete) 'food_subtotal': draft.subtotal,
      'total_price': s.printedTotal,
      'payment_type': s.paymentType,
      'cartMenuData': lines,
      '_isOffline': true,
      // Rung up at the till as its own order: listed, never counted twice.
      if (s.acknowledged) '_reconciled': true,
      '_syncStatus': _syncStatus(s, partialLines: !complete && lines.isNotEmpty),
    };
  }

  static String _syncStatus(OfflineSettlement s, {required bool partialLines}) {
    final String status;
    if (s.acknowledged) {
      status = 'Offline - reconciled at till';
    } else if (s.synced) {
      status = [
        'Offline - synced as ${s.orderNo ?? s.orderId ?? '?'}',
        if (s.mismatched)
          'server total ${s.serverTotal!.toStringAsFixed(2)}',
      ].join('; ');
    } else if (s.conflict || s.lastError != null) {
      status = 'Offline - needs attention: ${s.stuckReason}';
    } else {
      status = 'Offline - pending sync';
    }
    return partialLines
        ? '$status; items listed are only those not yet on the server'
        : status;
  }
}

class _TransactionReportScreenState extends State<TransactionReportScreen> {
  // ── state ───────────────────────────────────────────────────
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;
  // A source that failed while the other still has rows — shown as a banner.
  String? _onlineError;
  // Only the latest fetch may paint; an older, slower one is dropped.
  int _fetchSeq = 0;
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

  /// Server orders and this tablet's offline settlements, fetched apart: a
  /// failed server call must never hide the bills saved on the device —
  /// offline they are the only record, and the CSV is how staff reconcile.
  Future<void> _fetchOrders() async {
    final seq = ++_fetchSeq;
    setState(() {
      _loading = true;
      _error = null;
      _onlineError = null;
    });
    // The server's days are UTC: ask one day wider each side and trim to the
    // local range in mergeOrders.
    final fmt = DateFormat('yyyy-MM-dd');
    List<Map<String, dynamic>>? online;
    String? onlineError;
    try {
      online = await widget.posProvider.apiService.getOrders(
        from: fmt.format(_from.subtract(const Duration(days: 1))),
        to: fmt.format(_to.add(const Duration(days: 1))),
      );
    } catch (e) {
      onlineError = 'Server orders not loaded - showing bills saved on this '
          'tablet. ${e.toString().replaceAll('Exception: ', '')}';
    }

    var settlements = const <OfflineSettlement>[];
    try {
      final rid = await AuthService().getRestaurantId() ?? '';
      settlements = await widget.posProvider.drafts.allSettlements(rid);
    } catch (e) {
      onlineError = [
        ?onlineError,
        'Bills saved on this tablet could not be read: $e',
      ].join('\n');
    }

    final all = TransactionReportScreen.mergeOrders(
      online: online,
      settlements: settlements,
      from: DateTime(_from.year, _from.month, _from.day),
      to: DateTime(_to.year, _to.month, _to.day, 23, 59, 59),
    );
    if (!mounted || seq != _fetchSeq) return;
    setState(() {
      _orders = all;
      // Only a full-screen error when there is nothing at all to show.
      _error = all.isEmpty ? onlineError : null;
      _onlineError = all.isEmpty ? null : onlineError;
      _loading = false;
    });
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
      final rows = CsvExportService.buildRows(_orders);
      final file = await CsvExportService.saveCsv(
        CsvExportService.encode(rows),
        from: _from,
        to: _to,
      );
      if (!mounted) return;
      await _showSaved(file, rows);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Says exactly where the file is — the folder the waiter opens in the
  /// Files app and the file name — and offers to view or share it (Share is
  /// also how it is sent to WhatsApp / email / Drive or saved elsewhere).
  Future<void> _showSaved(File file, List<List<String>> rows) {
    final name = file.uri.pathSegments.last;
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF16A34A)),
            SizedBox(width: 8),
            Text('CSV saved'),
          ],
        ),
        content: SelectableText.rich(
          TextSpan(
            style: const TextStyle(fontSize: 13, height: 1.4),
            children: [
              const TextSpan(text: 'Folder\n', style: TextStyle(color: Colors.grey)),
              TextSpan(
                text: '${CsvExportService.folder}\n\n',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const TextSpan(text: 'File\n', style: TextStyle(color: Colors.grey)),
              TextSpan(
                text: '$name\n\n',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(
                text: 'Find it in the Files app under '
                    '${CsvExportService.folder.replaceAll('/', ' › ')}.',
                style: TextStyle(color: Colors.grey.shade700),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          TextButton.icon(
            icon: const Icon(Icons.table_view, size: 18),
            label: const Text('View'),
            onPressed: () => Navigator.push(
              ctx,
              MaterialPageRoute(
                builder: (_) => CsvPreviewScreen(fileName: name, rows: rows),
              ),
            ),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.share, size: 18),
            label: const Text('Share'),
            onPressed: () => SharePlus.instance.share(
              ShareParams(
                files: [XFile(file.path, mimeType: 'text/csv')],
                subject: name,
              ),
            ),
          ),
        ],
      ),
    );
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

  // Bills reconciled at the till are listed but counted by their till order.
  int get _totalOrders => _orders.where((o) => o['_reconciled'] != true).length;

  double get _totalRevenue {
    var sum = 0.0;
    for (final o in _orders) {
      if (o['_reconciled'] == true) continue;
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
          if (_onlineError != null)
            Container(
              width: double.infinity,
              color: Colors.orange.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.cloud_off, size: 16, color: Colors.orange.shade800),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _onlineError!,
                      style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
                    ),
                  ),
                ],
              ),
            ),
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
        (o['createdAt'] ?? o['created_at'] ?? '').toString())?.toLocal();
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
