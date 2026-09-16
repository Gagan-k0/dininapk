import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../providers/table_provider.dart';
import '../../providers/pos_provider.dart';
import '../../models/table_model.dart';
import '../../services/api_service.dart';
import '../../widgets/payment_mode_sheet.dart';

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
      Provider.of<TableProvider>(context, listen: false).ensureLoaded();
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
                auth.restaurantName.isEmpty
                    ? 'FATFOX DINE-IN'
                    : auth.restaurantName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF0F172A),
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
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
                auth.restaurantName.isEmpty
                    ? 'FATFOX RESTAURANT'
                    : auth.restaurantName,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              accountEmail: const Text(
                'Staff Dine-In Terminal',
                style: TextStyle(fontSize: 12),
              ),
              currentAccountPicture: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(
                  Icons.restaurant_menu,
                  color: Color(0xFFF97316),
                  size: 30,
                ),
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
              title: Text(
                'Pre Booking Dine In (${tableProv.reservations.length})',
              ),
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
              title: const Text(
                'Logout',
                style: TextStyle(color: Color(0xFFEF4444)),
              ),
              onTap: () async {
                tableProv.reset();
                Provider.of<PosProvider>(context, listen: false)
                    .clearFloorDirty();
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      color: Color(0xFF92400E),
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Demo mode — UI only. Tables/KOT/print need a real restaurant login (not superadmin).',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF92400E),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        tableProv.reset();
                        Provider.of<PosProvider>(context, listen: false)
                            .clearFloorDirty();
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 700;
                final tabs = <({int i, String label, IconData icon, Color color})>[
                  (i: 0, label: 'Dine In', icon: Icons.table_bar, color: Colors.orange),
                  (
                    i: 1,
                    label:
                        'Pre Booking Dine In (${tableProv.reservations.length})',
                    icon: Icons.calendar_today,
                    color: Colors.blue,
                  ),
                  (
                    i: 2,
                    label: 'Live Orders (${tableProv.liveOrders.length})',
                    icon: Icons.flash_on,
                    color: Colors.purple,
                  ),
                ];
                if (wide) {
                  return Row(
                    children: [
                      for (var t = 0; t < tabs.length; t++) ...[
                        if (t > 0) const SizedBox(width: 8),
                        Expanded(
                          child: _buildFullWidthSubTab(
                            tabs[t].i,
                            tabs[t].label,
                            tabs[t].icon,
                            tabs[t].color,
                            tableProv,
                          ),
                        ),
                      ],
                    ],
                  );
                }
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var t = 0; t < tabs.length; t++) ...[
                        if (t > 0) const SizedBox(width: 8),
                        _buildSubTabChip(
                          tabs[t].i,
                          tabs[t].label,
                          tabs[t].icon,
                          tabs[t].color,
                          tableProv,
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          const SizedBox(height: 4),

          // Dynamic Body based on Sub-Tab selection
          if (tableProv.isRefreshing)
            const LinearProgressIndicator(
              minHeight: 2,
              color: Color(0xFFF97316),
            ),
          Expanded(
            child: tableProv.isLoading && !tableProv.hasFloor
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFFF97316)),
                  )
                : _buildTabBody(tableProv),
          ),
        ],
      ),
    );
  }

  Widget _buildSubTabChip(
    int index,
    String label,
    IconData icon,
    Color activeColor,
    TableProvider prov,
  ) {
    final isSelected = prov.selectedTab == index;
    return ChoiceChip(
      showCheckmark: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      avatar: Icon(
        icon,
        size: 14,
        color: isSelected ? Colors.white : activeColor,
      ),
      label: Text(label),
      selected: isSelected,
      selectedColor: activeColor,
      backgroundColor: activeColor.withValues(alpha: 0.08),
      labelStyle: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: isSelected ? Colors.white : activeColor,
      ),
      onSelected: (_) => prov.setSelectedTab(index),
    );
  }

  /// Wide-layout tab that fills its [Expanded] slot (ChoiceChip cannot stretch).
  Widget _buildFullWidthSubTab(
    int index,
    String label,
    IconData icon,
    Color activeColor,
    TableProvider prov,
  ) {
    final isSelected = prov.selectedTab == index;
    return Material(
      color: isSelected ? activeColor : activeColor.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => prov.setSelectedTab(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: isSelected ? Colors.white : activeColor,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? Colors.white : activeColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabBody(TableProvider prov) {
    final hasError = prov.errorMessage != null && prov.errorMessage!.isNotEmpty;
    if (hasError && !prov.hasFloor) {
      return _buildFullError(prov);
    }

    return Column(
      children: [
        if (hasError) _buildStaleBanner(prov),
        Expanded(child: _buildTabContent(prov)),
      ],
    );
  }

  Widget _buildStaleBanner(TableProvider prov) {
    final expired = prov.sessionExpired;
    return Material(
      color: expired ? const Color(0xFFFEE2E2) : const Color(0xFFFEF3C7),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(
              expired ? Icons.lock_outline : Icons.cloud_off,
              size: 18,
              color: expired
                  ? const Color(0xFFB91C1C)
                  : const Color(0xFF92400E),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                expired
                    ? 'Session expired — log in again to keep working.'
                    : "Couldn't refresh the floor — showing what was loaded "
                          "${prov.lastSyncedLabel.isEmpty ? 'earlier' : prov.lastSyncedLabel}. "
                          "${prov.errorMessage}",
                style: TextStyle(
                  fontSize: 12,
                  color: expired
                      ? const Color(0xFFB91C1C)
                      : const Color(0xFF92400E),
                ),
              ),
            ),
            TextButton(
              onPressed: expired ? () => _relogin() : () => prov.refresh(),
              child: Text(
                expired ? 'LOG IN' : 'RETRY',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _relogin() async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    Provider.of<TableProvider>(context, listen: false).reset();
    Provider.of<PosProvider>(context, listen: false).clearFloorDirty();
    await auth.logout();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
  }

  Widget _buildFullError(TableProvider prov) {
    final expired = prov.sessionExpired;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              expired ? Icons.lock_outline : Icons.cloud_off,
              size: 48,
              color: const Color(0xFFEF4444),
            ),
            const SizedBox(height: 12),
            Text(
              expired ? 'Session expired' : "Couldn't load the floor",
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              prov.errorMessage ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!expired) ...[
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('RETRY'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF97316),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => prov.loadDashboardData(),
                  ),
                  const SizedBox(width: 12),
                ],
                OutlinedButton.icon(
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('RE-LOGIN'),
                  onPressed: _relogin,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent(TableProvider prov) {
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
      final areaTables = filteredTables
          .where((t) => t.areaId == area.id)
          .toList();
      if (areaTables.isNotEmpty) {
        grouped[area.name] = areaTables;
      }
    }

    // Add unassigned tables if any
    final assignedIds = prov.areas.map((a) => a.id).toSet();
    final unassigned = filteredTables
        .where((t) => !assignedIds.contains(t.areaId))
        .toList();
    if (unassigned.isNotEmpty) {
      grouped['Other Section'] = unassigned;
    }

    return Column(
      children: [
        // KPI Summary Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: Colors.white,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 700;
              final cards = <Widget>[
                _buildKpiCard(
                  'TOTAL TABLES',
                  '${prov.totalTablesCount}',
                  Colors.blue,
                  Icons.table_restaurant,
                  selected: prov.selectedStatusFilter == 'ALL',
                  onTap: () => prov.setStatusFilter('ALL'),
                  expand: wide,
                ),
                _buildKpiCard(
                  'AVAILABLE',
                  '${prov.availableTablesCount}',
                  Colors.green,
                  Icons.event_seat,
                  selected: prov.selectedStatusFilter == 'AVAILABLE',
                  onTap: () => prov.setStatusFilter('AVAILABLE'),
                  expand: wide,
                ),
                _buildKpiCard(
                  'OCCUPIED',
                  '${prov.occupiedTablesCount}',
                  Colors.orange,
                  Icons.people,
                  selected: prov.selectedStatusFilter == 'OCCUPIED',
                  onTap: () => prov.setStatusFilter('OCCUPIED'),
                  expand: wide,
                ),
                _buildKpiCard(
                  'KOT / RUNNING',
                  '${prov.kotTablesCount}',
                  Colors.purple,
                  Icons.receipt_long,
                  selected: prov.selectedStatusFilter == 'KOT',
                  onTap: () => prov.setStatusFilter('KOT'),
                  expand: wide,
                ),
              ];
              if (wide) {
                return Row(
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Expanded(child: cards[i]),
                    ],
                  ],
                );
              }
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: 10),
                      cards[i],
                    ],
                  ],
                ),
              );
            },
          ),
        ),
        const Divider(height: 1, color: Color(0xFFE2E8F0)),
        const SizedBox(height: 4),

        // Area Selection Filter Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          color: Colors.white,
          child: SizedBox(
            height: 32,
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
          child: RefreshIndicator(
            color: const Color(0xFFF97316),
            onRefresh: () => prov.refresh(),
            child: grouped.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 120),
                      Center(
                        child: Text(
                          'No tables found',
                          style: TextStyle(color: Color(0xFF64748B)),
                        ),
                      ),
                    ],
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final double maxExtent;
                      final double aspect;
                      if (w < 600) {
                        maxExtent = 200;
                        aspect = 1.05;
                      } else if (w < 900) {
                        maxExtent = 220;
                        aspect = 1.1;
                      } else {
                        maxExtent = 240;
                        aspect = 1.15;
                      }

                      return CustomScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          for (final entry in grouped.entries) ...[
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                                child: Text(
                                  entry.key,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFFE11D48),
                                  ),
                                ),
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              sliver: SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: maxExtent,
                                  childAspectRatio: aspect,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final table = entry.value[index];
                                    return _buildTableCard(
                                      context,
                                      prov,
                                      table,
                                    );
                                  },
                                  childCount: entry.value.length,
                                ),
                              ),
                            ),
                            const SliverToBoxAdapter(
                              child: SizedBox(height: 8),
                            ),
                          ],
                          const SliverToBoxAdapter(
                            child: SizedBox(height: 16),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildKpiCard(
    String label,
    String value,
    Color color,
    IconData icon, {
    bool selected = false,
    VoidCallback? onTap,
    bool expand = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: expand ? null : 130,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 0.18 : 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: color.withValues(alpha: selected ? 0.9 : 0.2),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAreaChip(TableProvider prov, String? areaId, String name) {
    final isSelected = prov.selectedAreaId == areaId;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        selected: isSelected,
        label: Text(name),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        labelPadding: const EdgeInsets.symmetric(horizontal: 8),
        labelStyle: TextStyle(
          fontSize: 11,
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

  String? _cartIdForTable(DineInTable table) => table.cartId;

  Future<void> _openPos(
    BuildContext context,
    TableProvider tableProv,
    DineInTable table,
  ) async {
    await Navigator.pushNamed(
      context,
      '/food-categories',
      arguments: {'tableId': table.id, 'areaId': table.areaId},
    );
    if (!context.mounted) return;
    final pos = Provider.of<PosProvider>(context, listen: false);
    if (pos.consumeFloorDirty()) {
      await tableProv.refresh();
    } else {
      await tableProv.ensureLoaded();
    }
  }

  void _toast(String text, {bool error = false, Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor:
            color ??
            (error ? const Color(0xFFEF4444) : const Color(0xFF16A34A)),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
        .where(
          (t) =>
              t.isAvailable && t.id != source.id && t.areaId == source.areaId,
        )
        .toList();
    final blankOthers = tableProv.tables
        .where(
          (t) =>
              t.isAvailable && t.id != source.id && t.areaId != source.areaId,
        )
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
                            selectedTileColor: const Color(0xFFF97316)
                                .withValues(alpha: 0.08),
                            leading: Icon(
                              selected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              color: const Color(0xFFF97316),
                              size: 20,
                            ),
                            title: Text(
                              'Table ${t.tableNumber}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            subtitle: Text(
                              sameArea ? 'Same area' : 'Other area',
                              style: TextStyle(
                                fontSize: 11,
                                color: sameArea
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFF64748B),
                              ),
                            ),
                            onTap: () =>
                                setDialogState(() => selectedId = t.id),
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
                  onPressed: selectedId == null
                      ? null
                      : () => Navigator.pop(ctx, true),
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

    final ok = await tableProv.shiftTable(
      cartId: cartId,
      newTableId: selectedId!,
    );
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

    if (!context.mounted) return;
    await _openPos(context, tableProv, table);
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

  Widget _buildTableCard(
    BuildContext context,
    TableProvider tableProv,
    DineInTable table,
  ) {
    // Admin dinein-table-list pastel tokens.
    final Color bg;
    final Color border;
    final bool dashed;
    if (table.isPending) {
      bg = const Color(0xFFF3E8FF);
      border = const Color(0xFFA78BFA);
      dashed = false;
    } else if (table.isPaid) {
      bg = const Color(0xFFFFEDD5);
      border = const Color(0xFFFB923C);
      dashed = false;
    } else if (table.isPrinted) {
      bg = const Color(0xFFDCFCE7);
      border = const Color(0xFF4ADE80);
      dashed = false;
    } else if (table.isKot ||
        table.tableStatus == 'RUNNING' ||
        table.isOccupied) {
      // Occupied / KOT / RUNNING → yellow wash (admin status-kot / running).
      bg = const Color(0xFFFEF9C3);
      border = const Color(0xFFFACC15);
      dashed = false;
    } else {
      bg = Colors.white;
      border = const Color(0xFFCBD5E1);
      dashed = true;
    }

    final cartId = table.cartId;
    final canShift = table.isOccupied && !table.isPending && cartId != null;
    final mins = table.seatedMinutes;
    final covers = () {
      final g = table.cartDetails?['no_of_guest'] ??
          table.cartDetails?['no_of_people'] ??
          table.reservation?['reservation_members'];
      return int.tryParse(g?.toString() ?? '') ?? table.noOfPeople;
    }();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          if (table.isPending) {
            _toast(
              'Accept the QR order first to open POS',
              color: const Color(0xFF7C3AED),
            );
            return;
          }
          _openPos(context, tableProv, table);
        },
        onLongPress: canShift
            ? () => _showShiftTableDialog(context, tableProv, table)
            : null,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: dashed
                ? null
                : Border.all(color: border, width: 1.5),
          ),
          child: CustomPaint(
            foregroundPainter: dashed
                ? _DashedBorderPainter(color: border, radius: 14)
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              child: Column(
                children: [
                  if (table.isOccupied) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            mins != null ? '$mins Min' : '—',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '• $covers Covers',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF64748B),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          table.tableNumber,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                            height: 1.1,
                          ),
                        ),
                        if (table.isOccupied) ...[
                          const SizedBox(height: 2),
                          Text(
                            '₹${table.totalPrice.toStringAsFixed(2)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                        ],
                        const SizedBox(height: 2),
                        Text(
                          '[${table.noOfPeople} Seats]',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (table.isPending && cartId != null) ...[
                        _floorActionChip(
                          Icons.check,
                          const Color(0xFF16A34A),
                          'Accept',
                          () => _acceptQrOrder(context, tableProv, table),
                        ),
                        const SizedBox(width: 6),
                        _floorActionChip(
                          Icons.close,
                          const Color(0xFFDC2626),
                          'Reject',
                          () => _rejectQrOrder(context, tableProv, table),
                        ),
                      ] else ...[
                        _floorActionChip(
                          Icons.visibility_outlined,
                          const Color(0xFF64748B),
                          'View',
                          () => _showTableQuickView(context, table),
                        ),
                        if (table.isOccupied && !table.isPending) ...[
                          const SizedBox(width: 6),
                          _floorActionChip(
                            Icons.print_outlined,
                            const Color(0xFF64748B),
                            'Print bill',
                            () => _printBillFromFloor(context, tableProv, table),
                          ),
                          const SizedBox(width: 6),
                          _floorActionChip(
                            Icons.check_circle_outline,
                            table.canRelease
                                ? const Color(0xFF16A34A)
                                : const Color(0xFF94A3B8),
                            'Settle',
                            table.canRelease
                                ? () => _settleFromFloor(
                                      context,
                                      tableProv,
                                      table,
                                    )
                                : () => _toast(
                                      'Print the bill before settling',
                                      color: const Color(0xFFD97706),
                                    ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _floorActionChip(
    IconData icon,
    Color color,
    String tooltip,
    VoidCallback onPressed,
  ) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 1,
        shadowColor: Colors.black26,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }

  Future<void> _showTableQuickView(
    BuildContext context,
    DineInTable table,
  ) async {
    final tableProv = Provider.of<TableProvider>(context, listen: false);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: ApiService().getCartItemsByTableId(table.id),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 160,
                child: Center(
                  child: CircularProgressIndicator(color: Color(0xFFF97316)),
                ),
              );
            }
            final carts = snap.data ?? const [];
            final cart = carts.isNotEmpty ? carts.first : null;
            final lines = cart?['cartMenuData'];
            final items = lines is List
                ? lines.whereType<Map>().where(
                      (m) =>
                          m['cancel_status'] != 1 && m['cancel_status'] != '1',
                    )
                : const Iterable.empty();
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Table ${table.tableNumber}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '₹${table.totalPrice.toStringAsFixed(2)} · ${table.tableStatus}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            'No items on this table',
                            style: TextStyle(color: Color(0xFF94A3B8)),
                          ),
                        ),
                      )
                    else
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                        ),
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final m in items)
                              ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  () {
                                    final md = m['menuData'];
                                    if (md is List &&
                                        md.isNotEmpty &&
                                        md.first is Map) {
                                      final row = Map<String, dynamic>.from(
                                        md.first as Map,
                                      );
                                      return (row['displayname'] ??
                                              row['name'] ??
                                              'Item')
                                          .toString();
                                    }
                                    return (m['menu_name'] ?? 'Item')
                                        .toString();
                                  }(),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                trailing: Text(
                                  'x${m['quantity'] ?? 1}',
                                  style: const TextStyle(
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(sheetCtx);
                          _openPos(this.context, tableProv, table);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF97316),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('Open POS'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _printBillFromFloor(
    BuildContext context,
    TableProvider tableProv,
    DineInTable table,
  ) async {
    final pos = Provider.of<PosProvider>(context, listen: false);
    _toast('Preparing bill…', color: const Color(0xFF64748B));
    final err = await pos.printBillForFloorTable(
      tableId: table.id,
      areaId: table.areaId,
    );
    if (!mounted) return;
    _toast(
      err ?? 'Bill printed ✓',
      error: err != null,
      color: err == null ? const Color(0xFF16A34A) : null,
    );
    await tableProv.refresh();
  }

  Future<void> _settleFromFloor(
    BuildContext context,
    TableProvider tableProv,
    DineInTable table,
  ) async {
    final cartId = table.cartId;
    if (cartId == null || cartId.isEmpty) {
      _toast('No cart on this table', error: true);
      return;
    }
    if (!table.canRelease) {
      _toast('Print the bill before settling', color: const Color(0xFFD97706));
      return;
    }
    final mode = await showPaymentModeSheet(
      context,
      title: 'Settle Table ${table.tableNumber}',
      amount: table.totalPrice,
    );
    if (mode == null || !context.mounted) return;
    final ok = await tableProv.settleTable(
      cartId: cartId,
      paymentType: mode,
    );
    if (!context.mounted) return;
    _toast(
      ok ? 'Table settled ✓' : (tableProv.errorMessage ?? 'Settle failed'),
      error: !ok,
      color: ok ? const Color(0xFF16A34A) : null,
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
            Text(
              'No Pre-Booking Reservations Found',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: prov.reservations.length,
      itemBuilder: (context, index) {
        final item = prov.reservations[index];
        final user = item['user'] is Map ? item['user'] as Map : const {};
        final name = (item['customer_name'] ?? user['name'] ?? 'Guest')
            .toString();
        final phone = (item['customer_mobile'] ?? user['mobile'] ?? '')
            .toString();
        final tableNos =
            item['table_numbers'] is List &&
                (item['table_numbers'] as List).isNotEmpty
            ? (item['table_numbers'] as List).join(' + ')
            : (item['table_number'] ?? '—').toString();
        final tableNo = tableNos;
        final guests =
            item['reservation_members'] ?? item['no_of_people'] ?? '';
        // reservation_date is a wall-clock labelled Z: read the UTC date parts.
        final rd = DateTime.tryParse(item['reservation_date']?.toString() ?? '')
            ?.toUtc();
        final dateStr = rd == null
            ? ''
            : '${rd.day.toString().padLeft(2, '0')}/${rd.month.toString().padLeft(2, '0')}';
        final timeStr = [
          dateStr,
          (item['reservation_time'] ?? '').toString(),
        ].where((e) => e.isNotEmpty).join(' ');
        final state =
            (item['state'] ??
                    (item['accepted_status'] == 1 ? 'CONFIRMED' : 'REQUESTED'))
                .toString();

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
            title: Text(
              name,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            subtitle: Text('📞 $phone • 👥 $guests Guests • ⏰ $timeStr'),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  'Table $tableNo',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFF97316),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCFCE7),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    state,
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Safe nested map get — `table_id` is often a bare ObjectId string from the API.
  dynamic _mapGet(dynamic value, String key) =>
      value is Map ? value[key] : null;

  double _asDouble(dynamic value, [double fallback = 0]) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  String _liveOrderTableLabel(Map<String, dynamic> order, TableProvider prov) {
    final fromNested =
        _mapGet(order['table_id'], 'table_number') ??
        _mapGet(order['table_id'], 'table_no');
    if (fromNested != null && fromNested.toString().isNotEmpty) {
      return fromNested.toString();
    }
    final direct = order['table_number'] ?? order['table_no'];
    if (direct != null && direct.toString().isNotEmpty) {
      return direct.toString();
    }
    final tableId = order['table_id'] is Map
        ? (_mapGet(order['table_id'], '_id') ??
                  _mapGet(order['table_id'], 'id'))
              ?.toString()
        : order['table_id']?.toString();
    if (tableId != null && tableId.isNotEmpty) {
      for (final t in prov.tables) {
        if (t.id == tableId) return t.tableNumber;
      }
    }
    return '—';
  }

  Color _statusColor(String status) {
    switch (status.toUpperCase()) {
      case 'PENDING':
        return const Color(0xFFD97706);
      case 'KOT':
      case 'KOT_PRINT':
        return const Color(0xFF2563EB);
      case 'PRINTED':
        return const Color(0xFF7C3AED);
      case 'RUNNING':
        return const Color(0xFF059669);
      default:
        return const Color(0xFF64748B);
    }
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
            Text(
              'No Live Active Dine-In Orders',
              style: TextStyle(
                color: Color(0xFF64748B),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: prov.liveOrders.length,
      itemBuilder: (context, index) {
        final order = prov.liveOrders[index];
        final orderId = (order['_id'] ?? order['id'] ?? 'ORD-${index + 1}')
            .toString();
        final tableNo = _liveOrderTableLabel(order, prov);
        final total = _asDouble(
          order['grand_total'] ?? order['total_price'] ?? order['menu_total'],
        );
        final status = (order['table_status'] ?? 'ACTIVE')
            .toString()
            .toUpperCase();
        final guest = order['customer_name']?.toString();
        final statusColor = _statusColor(status);

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
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.flash_on, color: statusColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Table $tableNo',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        guest != null && guest.isNotEmpty
                            ? '$guest · ${orderId.length > 8 ? orderId.substring(orderId.length - 8) : orderId}'
                            : 'Cart …${orderId.length > 8 ? orderId.substring(orderId.length - 8) : orderId}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '₹${total.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: Color(0xFFF97316),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        status,
                        style: TextStyle(
                          fontSize: 10,
                          color: statusColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
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

/// Admin-style dashed outline for available (BLANK) table cards.
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dashWidth = 5.0;
    const dashSpace = 3.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, next.clamp(0, metric.length)),
          paint,
        );
        distance = next + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
