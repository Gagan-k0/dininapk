import 'package:flutter/material.dart';

import '../services/subscription_service.dart';

/// Strip under the app bar while the subscription is `expiring` (amber) or in
/// `grace` (red). Hidden otherwise.
class SubscriptionBanner extends StatelessWidget {
  const SubscriptionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final service = SubscriptionService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final s = service.current;
        if (s == null || !s.showsBanner) return const SizedBox.shrink();
        final grace = s.state == 'grace';
        final days = grace
            ? _daysUntil(s.graceEndsAt)
            : (s.daysLeft ?? _daysUntil(s.endsAt));
        final text = grace
            ? 'Subscription expired — renew within $days ${days == 1 ? 'day' : 'days'} or the app will lock.'
            : 'Subscription ends in $days ${days == 1 ? 'day' : 'days'}. Contact FatFox to renew.';
        final support = s.supportPhone.isNotEmpty ? s.supportPhone : s.supportEmail;
        final color = grace ? const Color(0xFFDC2626) : const Color(0xFFD97706);
        return Material(
          color: grace ? const Color(0xFFFEE2E2) : const Color(0xFFFEF3C7),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: color, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    support.isEmpty ? text : '$text Support: $support',
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static int _daysUntil(DateTime? at) {
    if (at == null) return 0;
    final d = at.difference(DateTime.now().toUtc());
    return d.isNegative ? 0 : (d.inHours / 24).ceil();
  }
}
