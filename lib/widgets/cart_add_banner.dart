import 'package:flutter/material.dart';

/// Compact "Added …" pill for the POS AppBar — one banner, not a SnackBar stack.
class CartAddBanner extends StatelessWidget {
  final String message;
  final VoidCallback? onUndo;
  final VoidCallback? onDismiss;
  final bool busy;
  /// Narrow toolbars: icon Undo instead of the "Undo" label.
  final bool compact;

  const CartAddBanner({
    super.key,
    required this.message,
    this.onUndo,
    this.onDismiss,
    this.busy = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF16A34A),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: EdgeInsets.fromLTRB(compact ? 8 : 10, 4, 2, 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 14, color: Colors.white),
            const SizedBox(width: 6),
            Flexible(
              fit: FlexFit.loose,
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 11 : 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (onUndo != null)
              compact
                  ? IconButton(
                      onPressed: busy ? null : onUndo,
                      tooltip: 'Undo',
                      icon: const Icon(Icons.undo, size: 16, color: Colors.white),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      visualDensity: VisualDensity.compact,
                    )
                  : TextButton(
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
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
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
