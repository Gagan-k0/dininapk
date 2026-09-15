import '../models/menu_model.dart';

/// Port of admin `pickup-menu-filter.ts`.
///
/// `by-category-itemin` returns nested `category: [[{ name }]]` with ids stripped,
/// so tabs must match by category **name** (and optionally by id when present).

bool itemInCategoryNames(MenuItem item, List<String> categoryNames) {
  final wanted = categoryNames
      .map((n) => n.trim().toLowerCase())
      .where((n) => n.isNotEmpty)
      .toSet();
  if (wanted.isEmpty) return false;
  return item.categoryNames.any(
    (n) => wanted.contains(n.trim().toLowerCase()),
  );
}

bool itemMatchesCategoryId(MenuItem item, String categoryId) {
  if (categoryId.isEmpty) return false;
  if (item.categoryId == categoryId) return true;
  return item.categoryIds.contains(categoryId);
}

/// Filter the cached full menu like admin `filterOfflineMenu`.
///
/// When [alreadySorted] is true, skip the O(n log n) sort (caller keeps
/// the source list sorted by label).
List<MenuItem> filterMenuItems({
  required List<MenuItem> items,
  List<String> categoryNames = const [],
  String? categoryId,
  String search = '',
  bool alreadySorted = false,
}) {
  Iterable<MenuItem> out = items;
  final names = categoryNames.where((n) => n.trim().isNotEmpty).toList();
  final id = (categoryId ?? '').trim();

  if (names.isNotEmpty || id.isNotEmpty) {
    out = out.where((it) {
      final byName = names.isNotEmpty && itemInCategoryNames(it, names);
      final byId = id.isNotEmpty && itemMatchesCategoryId(it, id);
      return byName || byId;
    });
  }

  final term = search.trim().toLowerCase();
  if (term.isNotEmpty) {
    out = out.where((it) {
      final label = it.label.toLowerCase();
      final code = (it.shortCode ?? '').toLowerCase();
      return label.contains(term) || code.contains(term);
    });
  }

  final list = out.toList();
  if (!alreadySorted) {
    list.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  }
  return list;
}

/// Stable key for menu page window resets (category + search).
String menuFilterFingerprint({
  String? categoryId,
  String search = '',
}) =>
    '${categoryId ?? ''}|${search.trim().toLowerCase()}';
