import 'package:flutter/material.dart';

import '../models/menu_model.dart';
import '../utils/extra_addons.dart';

/// Vertical category rail for dine-in POS (tablet-friendly).
/// Collapsible: expanded list or slim icon strip.
/// Special tiles: ALL / Favorites / Extra Add-ons (admin dine-in parity).
class PosCategoryRail extends StatelessWidget {
  const PosCategoryRail({
    super.key,
    required this.categories,
    required this.selectedCategoryId,
    required this.onSelect,
    required this.collapsed,
    required this.onToggleCollapsed,
    this.expandedWidth = 168,
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
    // ALL + Favorites + Extra Add-ons + DB categories
    final itemCount = categories.length + 3;
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
                      label: 'All',
                      icon: Icons.apps,
                      collapsed: collapsed,
                      selected: selectedCategoryId == null,
                      onTap: () => onSelect(null),
                    );
                  }
                  if (index == 1) {
                    return _CategoryRailTile(
                      label: 'Favorites',
                      icon: Icons.star_border,
                      collapsed: collapsed,
                      selected: selectedCategoryId == kFavoritesCategoryId,
                      onTap: () => onSelect(kFavoritesCategoryId),
                    );
                  }
                  if (index == 2) {
                    return _CategoryRailTile(
                      label: 'Extra Add-ons',
                      icon: Icons.add_circle_outline,
                      collapsed: collapsed,
                      selected: selectedCategoryId == kExtraAddonsCategoryId,
                      onTap: () => onSelect(kExtraAddonsCategoryId),
                    );
                  }
                  final cat = categories[index - 3];
                  return _CategoryRailTile(
                    label: cat.categoryName,
                    imageUrl: cat.image,
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
    this.icon,
    this.imageUrl,
  });

  final String label;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;
  final IconData? icon;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final trimmed = label.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
    final accent = const Color(0xFFF97316);
    final bg = selected ? const Color(0xFFFFF7ED) : Colors.white;
    final border = selected ? accent : const Color(0xFFE2E8F0);
    final fg = selected ? accent : const Color(0xFF1E293B);

    Widget leading() {
      if (imageUrl != null && imageUrl!.trim().isNotEmpty) {
        return ClipOval(
          child: Image.network(
            imageUrl!,
            width: collapsed ? 22 : 28,
            height: collapsed ? 22 : 28,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _iconOrInitial(initial, fg),
          ),
        );
      }
      if (icon != null) {
        return Icon(icon, size: collapsed ? 18 : 20, color: fg);
      }
      return _iconOrInitial(initial, fg);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 0 : 10,
              vertical: collapsed ? 12 : 10,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border, width: selected ? 1.5 : 1),
            ),
            child: collapsed
                ? Center(child: leading())
                : Row(
                    children: [
                      leading(),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                            color: fg,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: selected ? accent : const Color(0xFFCBD5E1),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _iconOrInitial(String initial, Color fg) {
    return Container(
      width: collapsed ? 22 : 28,
      height: collapsed ? 22 : 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }
}
