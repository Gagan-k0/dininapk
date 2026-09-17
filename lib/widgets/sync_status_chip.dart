import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../providers/pos_provider.dart';
import '../services/connectivity_service.dart';
import '../services/draft_cart_store.dart';

/// App-bar chip: Online / No signal / Sync off. Tapping opens the Sync switch.
/// On the POS screen, pass [menuUpdatedAt] + [onSyncMenu] to add the menu row.
class SyncStatusChip extends StatelessWidget {
  final DateTime? menuUpdatedAt;
  final VoidCallback? onSyncMenu;

  const SyncStatusChip({super.key, this.menuUpdatedAt, this.onSyncMenu});

  static ({String label, Color color, IconData icon}) look(SyncState s) =>
      switch (s) {
        SyncState.online => (
          label: 'Online',
          color: const Color(0xFF16A34A),
          icon: Icons.cloud_done_outlined,
        ),
        SyncState.offlineNoSignal => (
          label: 'No signal',
          color: const Color(0xFFD97706),
          icon: Icons.cloud_off_outlined,
        ),
        SyncState.offlineManual => (
          label: 'Sync off',
          color: const Color(0xFF64748B),
          icon: Icons.sync_disabled,
        ),
      };

  /// "just now", "5m ago", "3h ago", "2d ago".
  static String ago(DateTime at, [DateTime? now]) {
    final d = (now ?? DateTime.now()).difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final net = ConnectivityService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([net, DraftCartStore.pendingTables]),
      builder: (context, _) {
        final l = look(net.state);
        final pending = DraftCartStore.pendingTables.value;
        // Phones: the POS search field needs the width, so show the icon only.
        if (MediaQuery.sizeOf(context).width < 600) {
          return IconButton(
            tooltip: 'Sync: ${l.label}',
            icon: Badge(
              isLabelVisible: pending > 0,
              label: Text('$pending'),
              child: Icon(l.icon, color: l.color),
            ),
            onPressed: () => _openSheet(context),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Semantics(
            button: true,
            label: 'Sync status: ${l.label}',
            child: ActionChip(
              avatar: Icon(l.icon, size: 16, color: l.color),
              label: Text(
                pending > 0 ? '${l.label} · $pending unsent' : l.label,
                style: TextStyle(
                  color: l.color,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              side: BorderSide(color: l.color.withValues(alpha: 0.35)),
              backgroundColor: l.color.withValues(alpha: 0.08),
              visualDensity: VisualDensity.compact,
              onPressed: () => _openSheet(context),
            ),
          ),
        );
      },
    );
  }

  void _openSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: Listenable.merge([
          ConnectivityService.instance,
          DraftCartStore.pendingTables,
        ]),
        builder: (sheetContext, _) {
          final net = ConnectivityService.instance;
          final pending = DraftCartStore.pendingTables.value;
          final noSignal = net.state == SyncState.offlineNoSignal;
          final updated = menuUpdatedAt;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    title: const Text('Sync with server'),
                    subtitle: Text(
                      net.syncOff
                          ? 'Off — nothing is sent. KOT, bill and settle need Sync on.'
                          : noSignal
                          ? 'On — server unreachable, retrying every 20s.'
                          : 'On — connected.',
                    ),
                    value: !net.syncOff,
                    onChanged: net.setSyncOn,
                  ),
                  if (pending > 0)
                    ListTile(
                      leading: const Icon(Icons.outbox_outlined),
                      title: Text(
                        'Unsent items on $pending table${pending == 1 ? '' : 's'}',
                      ),
                      subtitle: const Text(
                        'Held items wait on their table until you choose.',
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: net.isOnline
                            ? () => Provider.of<PosProvider>(
                                context,
                                listen: false,
                              ).flushAllDrafts()
                            : null,
                        child: const Text('Send now'),
                      ),
                    ),
                  if (onSyncMenu != null)
                    ListTile(
                      leading: const Icon(Icons.restaurant_menu),
                      title: const Text('Menu'),
                      subtitle: Text(
                        updated == null
                            ? 'Not downloaded yet'
                            : 'Updated ${ago(updated)}',
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: !net.syncOff
                            ? () {
                                Navigator.pop(sheetContext);
                                onSyncMenu!();
                              }
                            : null,
                        child: const Text('Sync menu'),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
