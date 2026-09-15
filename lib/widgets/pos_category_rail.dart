import 'package:flutter/material.dart';

import '../models/menu_model.dart';

/// Vertical category rail for dine-in POS (tablet-friendly).
/// Selection logic matches admin: null id = ALL; otherwise category id.
class PosCategoryRail extends StatelessWidget {
  const PosCategoryRail({
    super.key,
    required this.categories,
    required this.selectedCategoryId,
    required this.onSelect,
    this.width = 128,
  });

  final List<MenuCategory> categories;
  final String? selectedCategoryId;
  final ValueChanged<String?> onSelect;
  final double width;

  @override
  Widget build(BuildContext context) {
    final itemCount = categories.length + 1; // ALL + categories

    return Material(
      color: Colors.white,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: Text(
                'CATEGORIES',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _CategoryRailTile(
                      label: 'ALL',
                      selected: selectedCategoryId == null,
                      onTap: () => onSelect(null),
                    );
                  }
                  final cat = categories[index - 1];
                  return _CategoryRailTile(
                    label: cat.categoryName,
                    selected: selectedCategoryId == cat.id,
                    onTap: () => onSelect(cat.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryRailTile extends StatelessWidget {
  const _CategoryRailTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? const Color(0xFFF97316) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? const Color(0xFFF97316)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            child: Text(
              label.toUpperCase(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                height: 1.2,
                letterSpacing: 0.2,
                color: selected ? Colors.white : const Color(0xFF334155),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
