import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../services/connectivity_service.dart';
import '../../services/subscription_service.dart';

/// Renew screen shown over the whole app while [SubscriptionService.isLocked].
/// Makes no data calls; "Check again" only asks for the subscription status.
class SubscriptionLockedScreen extends StatefulWidget {
  final Future<void> Function() onSignOut;

  const SubscriptionLockedScreen({super.key, required this.onSignOut});

  @override
  State<SubscriptionLockedScreen> createState() => _SubscriptionLockedScreenState();
}

class _SubscriptionLockedScreenState extends State<SubscriptionLockedScreen> {
  bool _checking = false;

  Future<void> _checkAgain() async {
    setState(() => _checking = true);
    await SubscriptionService.instance.refresh();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final service = SubscriptionService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([service, ConnectivityService.instance]),
      builder: (context, _) {
        final s = service.current;
        final online = ConnectivityService.instance.isOnline;
        final blocked = s?.state == 'blocked';
        final title = blocked ? 'Restaurant blocked' : 'Subscription expired';
        final message = blocked
            ? 'This restaurant has been blocked. Contact FatFox support.'
            : !online && (s == null || !s.refuses)
            ? 'This tablet has been offline too long to confirm the subscription. Connect to the internet and check again.'
            : 'Your FatFox subscription has ended. Contact FatFox to renew — unsent items stay on this tablet and send after renewal.';
        final ends = s?.endsAt;
        final contacts = [
          if ((s?.supportPhone ?? '').isNotEmpty) ('Phone', Icons.phone, s!.supportPhone),
          if ((s?.supportWhatsapp ?? '').isNotEmpty) ('WhatsApp', Icons.chat, s!.supportWhatsapp),
          if ((s?.supportEmail ?? '').isNotEmpty) ('Email', Icons.email_outlined, s!.supportEmail),
        ];
        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        blocked ? Icons.block : Icons.lock_clock,
                        size: 64,
                        color: const Color(0xFFDC2626),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFF475569)),
                      ),
                      if (ends != null && !blocked) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Ended on ${DateFormat('d MMM yyyy').format(ends.toLocal())}',
                          style: const TextStyle(color: Color(0xFF64748B)),
                        ),
                      ],
                      const SizedBox(height: 16),
                      for (final (label, icon, value) in contacts)
                        ListTile(
                          leading: Icon(icon, color: const Color(0xFFF97316)),
                          title: SelectableText(value),
                          subtitle: Text(label),
                          trailing: IconButton(
                            tooltip: 'Copy',
                            icon: const Icon(Icons.copy),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: value));
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                SnackBar(content: Text('$label copied')),
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _checking ? null : _checkAgain,
                        icon: _checking
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh),
                        label: const Text('Check again'),
                      ),
                      TextButton(
                        onPressed: widget.onSignOut,
                        child: const Text('Sign out'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
