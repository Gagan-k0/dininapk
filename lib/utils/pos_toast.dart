import 'package:flutter/material.dart';

/// Compact floating toast for non-add feedback (errors, held-items, etc.).
/// Stays in the menu column on tablets so it does not cover KOT / BILL / SETTLE.
void showPosToast(
  BuildContext context,
  String message, {
  Color? backgroundColor,
  bool error = false,
  Duration duration = const Duration(milliseconds: 900),
}) {
  if (!context.mounted) return;
  final wide = MediaQuery.sizeOf(context).width >= 720;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        duration: duration,
        backgroundColor: backgroundColor ??
            (error ? const Color(0xFFDC2626) : const Color(0xFF16A34A)),
        behavior: SnackBarBehavior.floating,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        margin: EdgeInsets.fromLTRB(16, 0, wide ? 356 : 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
}
