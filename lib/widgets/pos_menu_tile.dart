import 'package:flutter/material.dart';

/// Compact dine-in menu cell — white label panel + attribute stripe (admin POS parity).
class PosMenuTile extends StatelessWidget {
  const PosMenuTile({
    super.key,
    required this.label,
    required this.attribute,
    required this.inCart,
    required this.onTap,
    this.shortCode,
  });

  final String label;
  final String attribute;
  final bool inCart;
  final VoidCallback onTap;
  final String? shortCode;

  @override
  Widget build(BuildContext context) {
    final attr = attribute.toUpperCase().replaceAll('_', '');
    final isNonVeg = attr == 'NONVEG';
    final isEgg = attr == 'EGG';

    Color border = const Color(0xFF81C784);
    Color leftBar = const Color(0xFF2E7D32);
    Color labelBg = Colors.white;
    if (isNonVeg) {
      border = const Color(0xFFEF9A9A);
      leftBar = const Color(0xFFC62828);
    } else if (isEgg) {
      border = const Color(0xFFFFCC80);
      leftBar = const Color(0xFFFB8C00);
    }

    if (inCart) {
      border = const Color(0xFFFDBA74);
      leftBar = const Color(0xFFF97316);
      labelBg = const Color(0xFFFFF7ED);
    }

    final code = shortCode?.trim() ?? '';
    final showCode = code.isNotEmpty && code != label.trim();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: border),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColoredBox(
                  color: leftBar,
                  child: const SizedBox(width: 5),
                ),
                Expanded(
                  child: ColoredBox(
                    color: labelBg,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A),
                              letterSpacing: 0.15,
                            ),
                          ),
                          if (showCode)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '[ $code ]',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
