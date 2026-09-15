import 'package:flutter/material.dart';

/// Compact "Added …" strip under the cart header — one banner, not a SnackBar stack.
class CartAddBanner extends StatelessWidget {
  final String message;
  final VoidCallback? onUndo;
  final VoidCallback? onDismiss;
  final bool busy;

  const CartAddBanner({
    super.key,
    required this.message,
    this.onUndo,
    this.onDismiss,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF16A34A),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline, size: 14, color: Colors.white),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (onUndo != null)
              TextButton(
                onPressed: busy ? null : onUndo,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text(
                  'Undo',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            if (onDismiss != null)
              IconButton(
                onPressed: busy ? null : onDismiss,
                tooltip: 'Dismiss',
                icon: const Icon(Icons.close, size: 14, color: Colors.white),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }
}
