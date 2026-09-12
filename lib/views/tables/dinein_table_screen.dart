import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/table_provider.dart';
import '../../models/table_model.dart';
import '../../services/thermal_printer_service.dart';

class DineInTableScreen extends StatefulWidget {
  const DineInTableScreen({super.key});

  @override
  State<DineInTableScreen> createState() => _DineInTableScreenState();
}

class _DineInTableScreenState extends State<DineInTableScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<TableProvider>(context, listen: false).loadDashboardData();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);
    final tableProv = Provider.of<TableProvider>(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Row(
          children: [
            const Icon(Icons.restaurant, color: Color(0xFFF97316), size: 22),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                auth.restaurantName.isEmpty ? 'FATFOX DINE-IN' : auth.restaurantName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF0F172A), fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF64748B)),
            onPressed: () => tableProv.loadDashboardData(),
            tooltip: 'Refresh',
          ),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              decoration: const BoxDecoration(color: Color(0xFFF97316)),
              accountName: Text(
                auth.restaurantName.isEmpty ? 'FATFOX RESTAURANT' : auth.restaurantName,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              accountEmail: const Text('Staff Dine-In Terminal', style: TextStyle(fontSize: 12)),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.restaurant_menu, color: Color(0xFFF97316), size: 30),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.dashboard, color: Color(0xFFF97316)),
              title: const Text('Table Dashboard'),
              selected: tableProv.selectedTab == 0,
              onTap: () {
                tableProv.setSelectedTab(0);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.event_seat, color: Color(0xFF2563EB)),
              title: Text('Pre Booking Dine In (${tableProv.reservations.length})'),
              selected: tableProv.selectedTab == 1,
              onTap: () {
                tableProv.setSelectedTab(1);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long, color: Color(0xFFD97706)),
              title: Text('Live Orders (${tableProv.liveOrders.length})'),
              selected: tableProv.selectedTab == 2,
              onTap: () {
                tableProv.setSelectedTab(2);
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.restaurant, color: Color(0xFF10B981)),
              title: const Text('Food Categories & Menu'),
              onTap: () {
                // Real POS is table → /food-categories; do not open legacy /pos.
                tableProv.setSelectedTab(0);
                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(context);
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Open a table from the floor to take orders'),
                  ),
                );
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.print, color: Color(0xFF64748B)),
              title: const Text('Printer Settings'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/settings/printer');
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout, color: Color(0xFFEF4444)),
              title: const Text('Logout', style: TextStyle(color: Color(0xFFEF4444))),
              onTap: () async {
                await auth.logout();
                if (context.mounted) {
                  Navigator.pushReplacementNamed(context, '/login');
                }
              },
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (auth.isDemoMode)
            Material(
              color: const Color(0xFFFEF3C7),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Color(0xFF92400E), size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Demo mode — UI only. Tables/KOT/print need a real restaurant login (not superadmin).',
                        style: TextStyle(fontSize: 12, color: Color(0xFF92400E)),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await auth.logout();
                        if (context.mounted) {
                          Navigator.of(context).pushReplacementNamed('/login');
                        }
                      },
                      child: const Text('Exit', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ),
          // Top Sub-Tabs Navigation Bar (Dine In | Pre Booking Dine In | Live Orders)
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildSubTabChip(0, 'Dine In', Icons.table_bar, Colors.orange, tableProv),
                  const SizedBox(width: 8),
                  _buildSubTabChip(1, 'Pre Booking Dine In (${tableProv.reservations.length})', Icons.calendar_today, Colors.blue, tableProv),
                  const SizedBox(width: 8),
                  _buildSubTabChip(2, 'Live Orders (${tableProv.liveOrders.length})', Icons.flash_on, Colors.purple, tableProv),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),

          // Dynamic Body based on Sub-Tab selection
          Expanded(
            child: tableProv.isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFFF97316)))
                : _buildTabBody(tableProv),
          ),
        ],
      ),
    );
  }

  Widget _buildSubTabChip(int index, String label, IconData icon, Color activeColor, TableProvider prov) {
    final isSelected = prov.selectedTab == index;
    return ChoiceChip(
      showCheckmark: false,
      avatar: Icon(icon, size: 16, color: isSelected ? Colors.white : activeColor),
      label: Text(label),
      selected: isSelected,
      selectedColor: activeColor,
      backgroundColor: activeColor.withValues(alpha: 0.08),
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: isSelected ? Colors.white : activeColor,
      ),
      onSelected: (_) => prov.setSelectedTab(index),
    );
  }

  Widget _buildTabBody(TableProvider prov) {
    if (prov.errorMessage != null && prov.errorMessage!.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48, color: Color(0xFFEF4444)),
              const SizedBox(height: 12),
              Text(
                'Live Backend Error',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
              ),
              const SizedBox(height: 6),
              Text(
                prov.errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('RETRY LIVE SYNC'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF97316),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => prov.loadDashboardData(),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('RE-LOGIN'),
                    onPressed: () async {
                      final auth = Provider.of<AuthProvider>(context, listen: false);
                      await auth.logout();
                      if (!mounted) return;
                      Navigator.pushReplacementNamed(context, '/login');
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    switch (prov.selectedTab) {
      case 1:
        return _buildReservationsView(prov);
      case 2:
        return _buildLiveOrdersView(prov);
      case 0:
      default:
        return _buildDineInTablesDashboard(prov);
    }
  }

  // --- TAB 0: DINE-IN TABLES DASHBOARD WITH GROUPED AREAS ---
  Widget _buildDineInTablesDashboard(TableProvider prov) {
    final filteredTables = prov.filteredTables;

    // Group tables by Area Name
    final Map<String, List<DineInTable>> grouped = {};
    for (var area in prov.areas) {
      final areaTables = filteredTables.where((t) => t.areaId == area.id).toList();
      if (areaTables.isNotEmpty) {
        grouped[area.name] = areaTables;
      }
    }

    // Add unassigned tables if any
    final assignedIds = prov.areas.map((a) => a.id).toSet();
    final unassigned = filteredTables.where((t) => !assignedIds.contains(t.areaId)).toList();
    if (unassigned.isNotEmpty) {
      grouped['Other Section'] = unassigned;
    }

    return Column(
      children: [
        // KPI Summary Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: Colors.white,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildKpiCard('TOTAL TABLES', '${prov.totalTablesCount}', Colors.blue, Icons.table_restaurant),
                const SizedBox(width: 10),
                _buildKpiCard('AVAILABLE', '${prov.availableTablesCount}', Colors.green, Icons.event_seat),
                const SizedBox(width: 10),
                _buildKpiCard('OCCUPIED', '${prov.occupiedTablesCount}', Colors.orange, Icons.people),
                const SizedBox(width: 10),
                _buildKpiCard('KOT / RUNNING', '${prov.kotTablesCount}', Colors.purple, Icons.receipt_long),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFFE2E8F0)),

        // Area Selection Filter Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.white,
          child: SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildAreaChip(prov, null, 'ALL AREAS'),
                ...prov.areas.map((a) => _buildAreaChip(prov, a.id, a.name)),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFFE2E8F0)),

        // Grouped Area Headings & Table Grids
        Expanded(
          child: grouped.isEmpty
              ? const Center(child: Text('No tables found for this area', style: TextStyle(color: Color(0xFF64748B))))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: grouped.entries.map((entry) {
                    final areaName = entry.key;
                    final areaTables = entry.value;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                          child: Text(
                            areaName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFE11D48), // Dark Pink / Red Area Heading matching web
                            ),
                          ),
                        ),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            childAspectRatio: 1.05,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                          itemCount: areaTables.length,
                          itemBuilder: (context, index) {
                            return _buildTableCard(context, prov, areaTables[index]);
                          },
                        ),
                        const SizedBox(height: 16),
                      ],
                    );
                  }).toList(),
                ),
        ),
      ],
    );
  }

  Widget _buildKpiCard(String label, String value, Color color, IconData icon) {
    return Container(
      width: 135,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color),
                ),
                Text(
                  value,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAreaChip(TableProvider prov, String? areaId, String name) {
    final isSelected = prov.selectedAreaId == areaId;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: isSelected,
        label: Text(name),
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: isSelected ? Colors.white : const Color(0xFF64748B),
        ),
        selectedColor: const Color(0xFFF97316),
        backgroundColor: const Color(0xFFF1F5F9),
        checkmarkColor: Colors.white,
        onSelected: (_) => prov.selectArea(areaId),
      ),
    );
  }

  String? _cartIdForTable(DineInTable table) {
    final cart = table.cartDetails;
    if (cart == null) return null;
    final id = cart['_id']?.toString() ??
        cart['cart_id']?.toString() ??
        cart['cartId']?.toString();
    if (id == null || id.isEmpty) return null;
    return id;
  }

  Future<void> _showShiftTableDialog(
    BuildContext context,
    TableProvider tableProv,
    DineInTable source,
  ) async {
    final cartId = _cartIdForTable(source);
    if (cartId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active cart on this table'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    final blankSameArea = tableProv.tables
        .where((t) => t.isAvailable && t.id != source.id && t.areaId == source.areaId)
        .toList();
    final blankOthers = tableProv.tables
        .where((t) => t.isAvailable && t.id != source.id && t.areaId != source.areaId)
        .toList();
    final targets = [...blankSameArea, ...blankOthers];

    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No blank tables available to shift to'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    String? selectedId = targets.first.id;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Text('Shift Table ${source.tableNumber}'),
              content: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Move this order to a blank table:',
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: targets.length,
                        itemBuilder: (_, i) {
                          final t = targets[i];
                          final sameArea = t.areaId == source.areaId;
                          final selected = selectedId == t.id;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            selectedTileColor: const Color(0xFFF97316).withValues(alpha: 0.08),
                            leading: Icon(
                              selected ? Icons.radio_button_checked : Icons.radio_button_off,
                              color: const Color(0xFFF97316),
                              size: 20,
                            ),
                            title: Text(
                              'Table ${t.tableNumber}',
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                            ),
                            subtitle: Text(
                              sameArea ? 'Same area' : 'Other area',
                              style: TextStyle(
                                fontSize: 11,
                                color: sameArea ? const Color(0xFF16A34A) : const Color(0xFF64748B),
                              ),
                            ),
                            onTap: () => setDialogState(() => selectedId = t.id),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: selectedId == null ? null : () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF97316),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Shift'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true || selectedId == null || !context.mounted) return;

    final ok = await tableProv.shiftTable(cartId: cartId, newTableId: selectedId!);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Table shifted successfully'
              : (tableProv.errorMessage ?? 'Failed to shift table'),
        ),
        backgroundColor: ok ? const Color(0xFF16A34A) : const Color(0xFFEF4444),
      ),
    );
  }

  Future<void> _acceptQrOrder(
    BuildContext context,
    TableProvider tableProv,
    DineInTable table,
  ) async {
    final cartId = _cartIdForTable(table);
    if (cartId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active cart on this table'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    final ok = await tableProv.decideQrOrder(cartId: cartId, action: 'ACCEPT');
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Order accepted — sent to kitchen'
              : (tableProv.errorMessage ?? 'Failed to accept QR order'),
        ),
        backgroundColor: ok ? const Color(0xFF16A34A) : const Color(0xFFEF4444),
      ),
    );

    if (!ok) return;

    Navigator.pushNamed(
      context,
      '/food-categories',
      arguments: {
        'tableId': table.id,
        'areaId': table.areaId,
      },
    );
  }

  Future<void> _rejectQrOrder(
    BuildContext context,
    TableProvider tableProv,
    DineInTable table,
  ) async {
    final cartId = _cartIdForTable(table);
    if (cartId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active cart on this table'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reject Table ${table.tableNumber}?'),
        content: const Text(
          'This deletes the QR order and frees the table. The diner must re-order.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
            ),
            child: const Text('Reject order'),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;

    final ok = await tableProv.decideQrOrder(cartId: cartId, action: 'REJECT');
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Order rejected — table freed'
              : (tableProv.errorMessage ?? 'Failed to reject QR order'),
        ),
        backgroundColor: ok ? const Color(0xFF16A34A) : const Color(0xFFEF4444),
      ),
    );
  }

  Widget _buildTableCard(BuildContext context, TableProvider tableProv, DineInTable table) {
    Color cardBg = Colors.white;
    Color borderCol = const Color(0xFFE2E8F0);
    String statusText = 'AVAILABLE';
    Color badgeColor = const Color(0xFF64748B);

    if (table.isPending) {
      cardBg = const Color(0xFFF3E8FF); // soft purple
      borderCol = const Color(0xFFF59E0B); // amber border
      statusText = 'PENDING';
      badgeColor = const Color(0xFF7C3AED); // purple badge
    } else if (table.isKot) {
      cardBg = const Color(0xFFFEF3C7);
      borderCol = const Color(0xFFFCD34D);
      statusText = 'KOT RUNNING';
      badgeColor = const Color(0xFFD97706);
    } else if (table.isOccupied) {
      cardBg = const Color(0xFFDCFCE7);
      borderCol = const Color(0xFF86EFAC);
      statusText = 'OCCUPIED';
      badgeColor = const Color(0xFF15803D);
    }

    final covers = table.cartDetails?['covers'] ?? 4;
    final timeMins = table.cartDetails?['time_mins'] ?? '';
    final cartId = _cartIdForTable(table);
    final canShift = table.isOccupied && !table.isPending && cartId != null;

    return InkWell(
      onTap: () {
        if (table.isPending) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Accept the QR order first to open POS'),
              backgroundColor: Color(0xFF7C3AED),
            ),
          );
          return;
        }
        Navigator.pushNamed(
          context,
          '/food-categories',
          arguments: {
            'tableId': table.id,
            'areaId': table.areaId,
          },
        );
      },
      onLongPress: canShift
          ? () => _showShiftTableDialog(context, tableProv, table)
          : null,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderCol, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  table.tableNumber,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                ),
                Text(
                  '[${table.noOfPeople} Seats]',
                  style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                ),
              ],
            ),
            if (table.isOccupied) ...[
              if (timeMins.isNotEmpty)
                Text('$timeMins • $covers Covers', style: const TextStyle(fontSize: 9, color: Color(0xFF475569)))
              else
                Text('$covers Covers', style: const TextStyle(fontSize: 9, color: Color(0xFF475569))),
              Text(
                '₹${table.totalPrice.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
              ),
            ] else
              const Text('Tap to Order', style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),

            // Quick Action Buttons on Cards (Accept/Reject, Shift, Printer, Release)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: badgeColor),
                  ),
                ),
                if (table.isPending && cartId != null)
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.check, size: 16, color: Color(0xFF16A34A)),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Accept QR order',
                        onPressed: () => _acceptQrOrder(context, tableProv, table),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16, color: Color(0xFFDC2626)),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Reject QR order',
                        onPressed: () => _rejectQrOrder(context, tableProv, table),
                      ),
                    ],
                  )
                else if (table.isOccupied)
                  Row(
                    children: [
                      if (canShift) ...[
                        IconButton(
                          icon: const Icon(Icons.swap_horiz, size: 16, color: Color(0xFFF97316)),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Shift Table',
                          onPressed: () => _showShiftTableDialog(context, tableProv, table),
                        ),
                        const SizedBox(width: 6),
                      ],
                      IconButton(
                        icon: const Icon(Icons.print, size: 16, color: Color(0xFF2563EB)),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Quick Print Bill',
                        onPressed: () async {
                          final auth = Provider.of<AuthProvider>(context, listen: false);
                          final printerService = ThermalPrinterService();
                          try {
                            final bytes = await printerService.generateBillBytes(
                              table: table,
                              items: const [],
                              subTotal: table.totalPrice,
                              taxAmount: 0,
                              grandTotal: table.totalPrice,
                              restaurantName: auth.restaurantName,
                              paperSize: '80mm',
                            );
                            await printerService.printBytes(bytes);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Bill sent to printer'),
                                  backgroundColor: Color(0xFF2563EB),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    e.toString().replaceAll('Exception: ', ''),
                                  ),
                                  backgroundColor: const Color(0xFFEF4444),
                                ),
                              );
                            }
                          }
                        },
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.check_circle_outline, size: 16, color: Color(0xFF16A34A)),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Release Table',
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Release Table'),
                              content: Text('Mark Table ${table.tableNumber} paid and available?'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                                  child: const Text('Release'),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true) {
                            await tableProv.releaseTable(table.id);
                          }
                        },
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // --- TAB 1: PRE-BOOKING DINE IN ---
  Widget _buildReservationsView(TableProvider prov) {
    if (prov.reservations.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_seat, size: 48, color: Color(0xFFCBD5E1)),
            SizedBox(height: 12),
            Text('No Pre-Booking Reservations Found', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: prov.reservations.length,
      itemBuilder: (context, index) {
        final item = prov.reservations[index];
        final name = item['customer_name'] ?? item['name'] ?? 'Rahul Sharma';
        final phone = item['phone'] ?? item['mobile'] ?? '+91 98765 43210';
        final tableNo = item['table_number'] ?? item['table'] ?? '10';
        final guests = item['guest_count'] ?? item['no_of_people'] ?? 4;
        final timeStr = item['reservation_time'] ?? item['time'] ?? 'Today 07:30 PM';

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          elevation: 0,
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFDBEAFE),
              child: Icon(Icons.person, color: Color(0xFF2563EB)),
            ),
            title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            subtitle: Text('📞 $phone • 👥 $guests Guests • ⏰ $timeStr'),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Table $tableNo', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFF97316))),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFDCFCE7), borderRadius: BorderRadius.circular(4)),
                  child: const Text('CONFIRMED', style: TextStyle(fontSize: 9, color: Colors.green, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // --- TAB 2: LIVE ORDERS ---
  Widget _buildLiveOrdersView(TableProvider prov) {
    if (prov.liveOrders.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long, size: 48, color: Color(0xFFCBD5E1)),
            SizedBox(height: 12),
            Text('No Live Active Dine-In Orders', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.bold)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: prov.liveOrders.length,
      itemBuilder: (context, index) {
        final order = prov.liveOrders[index];
        final orderId = order['_id'] ?? order['id'] ?? 'ORD-#${index + 100}';
        final tableNo = order['table_id']?['table_number'] ?? order['table_number'] ?? '${(index % 25) + 1}';
        final total = (order['grand_total'] ?? order['total_price'] ?? ((index + 1) * 150.0)).toDouble();

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          elevation: 0,
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFFE2E8F0)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF3C7),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.flash_on, color: Color(0xFFD97706)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Table $tableNo', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('ID: $orderId', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('₹${total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFFF97316))),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: const Color(0xFFDBEAFE), borderRadius: BorderRadius.circular(4)),
                      child: const Text('ACTIVE KOT', style: TextStyle(fontSize: 10, color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
