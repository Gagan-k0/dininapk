import 'package:flutter/material.dart';

import '../providers/pos_provider.dart';
import '../services/connectivity_service.dart';

/// Shown when this table's unsent items were held back (the order changed,
/// another tablet holds the table, or a send may already have landed).
/// Nothing is sent again until the waiter chooses.
class HeldItemsBar extends StatelessWidget {
  final PosProvider pos;
  const HeldItemsBar({super.key, required this.pos});

  @override
  Widget build(BuildContext context) {
    final d = pos.draft;
    if (d == null || !d.conflict) return const SizedBox.shrink();
    final busy = pos.isBusy;
    return Material(
      color: const Color(0xFFFFEDD5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 4,
          children: [
            const Icon(Icons.pause_circle_outline, size: 18, color: Color(0xFF9A3412)),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                '${d.itemCount} unsent item${d.itemCount == 1 ? '' : 's'} held. '
                '${d.lastError ?? 'Check the order before sending.'}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF9A3412)),
              ),
            ),
            TextButton(
              onPressed: busy ? null : () => _discard(context),
              child: const Text('Discard'),
            ),
            FilledButton.tonal(
              onPressed: busy || !ConnectivityService.instance.isOnline
                  ? null
                  : () => _send(context),
              child: const Text('Send to current order'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirm(BuildContext context, String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _send(BuildContext context) async {
    if (!await _confirm(
      context,
      'Send held items?',
      'They will be added to the order open on this table now. '
          'Check that they are not already on it or on a closed bill.',
      'Send',
    )) {
      return;
    }
    final ok = await pos.resendDraft();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Held items sent' : (pos.errorMessage ?? 'Could not send')),
        backgroundColor: ok ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _discard(BuildContext context) async {
    if (await _confirm(
      context,
      'Discard held items?',
      pos.draft?.creatingLine != null
          ? 'One item may already be on the order — check it there. '
                'The rest were never added. This cannot be undone.'
          : 'They were never added to the order. This cannot be undone.',
      'Discard',
    )) {
      await pos.discardDraft();
    }
  }
}
