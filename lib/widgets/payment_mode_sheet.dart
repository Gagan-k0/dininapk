import 'package:flutter/material.dart';

/// Admin payment picker: exactly CASH / CARD / ONLINE (labelled UPI).
/// Returns the chosen enum or null when dismissed.
Future<String?> showPaymentModeSheet(
  BuildContext context, {
  required String title,
  double? amount,
  String initial = 'CASH',
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _PaymentModeSheet(title: title, amount: amount, initial: initial),
  );
}

class _PaymentModeSheet extends StatefulWidget {
  final String title;
  final double? amount;
  final String initial;
  const _PaymentModeSheet({required this.title, this.amount, required this.initial});

  @override
  State<_PaymentModeSheet> createState() => _PaymentModeSheetState();
}

class _PaymentModeSheetState extends State<_PaymentModeSheet> {
  late String _mode = widget.initial;

  static const _modes = [
    ('CASH', 'Cash', Icons.payments_outlined),
    ('CARD', 'Card', Icons.credit_card),
    ('ONLINE', 'UPI', Icons.qr_code_2),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
            if (widget.amount != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Amount to collect: ₹${widget.amount!.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (final m in _modes) ...[
                  Expanded(
                    child: InkWell(
                      onTap: () => setState(() => _mode = m.$1),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: _mode == m.$1 ? const Color(0xFFFFF1E8) : const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _mode == m.$1 ? const Color(0xFFF97316) : const Color(0xFFE2E8F0),
                            width: _mode == m.$1 ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          children: [
                            Icon(m.$3, color: _mode == m.$1 ? const Color(0xFFF97316) : const Color(0xFF64748B)),
                            const SizedBox(height: 6),
                            Text(
                              m.$2,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: _mode == m.$1 ? const Color(0xFFF97316) : const Color(0xFF334155),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (m != _modes.last) const SizedBox(width: 10),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context, _mode),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Confirm', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF16A34A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
