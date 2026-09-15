import 'package:flutter/material.dart';

import '../models/menu_model.dart';

/// Vertical category rail for dine-in POS (tablet-friendly).
/// Collapsible hamburger-style drawer: expanded list or slim icon strip.
class PosCategoryRail extends StatelessWidget {
  const PosCategoryRail({
    super.key,
    required this.categories,
    required this.selectedCategoryId,
    required this.onSelect,
    required this.collapsed,
    required this.onToggleCollapsed,
    this.expandedWidth = 160,
    this.collapsedWidth = 52,
  });

  final List<MenuCategory> categories;
  final String? selectedCategoryId;
  final ValueChanged<String?> onSelect;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final double expandedWidth;
  final double collapsedWidth;

  @override
  Widget build(BuildContext context) {
    final itemCount = categories.length + 1; // ALL + categories
    final width = collapsed ? collapsedWidth : expandedWidth;

    return Material(
      color: Colors.white,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                collapsed ? 4 : 8,
                8,
                collapsed ? 4 : 8,
                4,
              ),
              child: IconButton(
                tooltip: collapsed ? 'Expand categories' : 'Collapse categories',
                onPressed: onToggleCollapsed,
                icon: Icon(
                  collapsed ? Icons.menu : Icons.menu_open,
                  color: const Color(0xFF475569),
                ),
              ),
            ),
            if (!collapsed)
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
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
                padding: EdgeInsets.fromLTRB(
                  collapsed ? 6 : 8,
                  0,
                  collapsed ? 6 : 8,
                  12,
                ),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _CategoryRailTile(
                      label: 'ALL',
                      collapsed: collapsed,
                      selected: selectedCategoryId == null,
                      onTap: () => onSelect(null),
                    );
                  }
                  final cat = categories[index - 1];
                  return _CategoryRailTile(
                    label: cat.categoryName,
                    collapsed: collapsed,
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
    required this.collapsed,
  });

  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final trimmed = label.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();

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
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 0 : 10,
              vertical: collapsed ? 12 : 11,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected
                    ? const Color(0xFFF97316)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            child: collapsed
                ? Center(
                    child: Text(
                      initial,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: selected
                            ? Colors.white
                            : const Color(0xFF334155),
                      ),
                    ),
                  )
                : Text(
                    label.toUpperCase(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      letterSpacing: 0.2,
                      color: selected
                          ? Colors.white
                          : const Color(0xFF334155),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
