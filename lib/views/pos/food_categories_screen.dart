import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/pos_provider.dart';
import '../../models/menu_model.dart';
import '../../services/pos_ui_prefs.dart';
import '../../utils/extra_addons.dart';
import '../../utils/menu_filter.dart';
import '../../utils/menu_page_window.dart';
import '../../widgets/pos_category_rail.dart';
import '../../widgets/pos_menu_tile.dart';

class FoodCategoriesScreen extends StatefulWidget {
  const FoodCategoriesScreen({super.key});

  @override
  State<FoodCategoriesScreen> createState() => _FoodCategoriesScreenState();
}

class _FoodCategoriesScreenState extends State<FoodCategoriesScreen> {
  bool _initialized = false;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _cartScrollController = ScrollController();
  final ScrollController _menuScrollController = ScrollController();
  final MenuPageWindow<MenuItem> _menuPage =
      MenuPageWindow<MenuItem>(pageSize: 80);
  Timer? _searchDebounce;
  bool _railCollapsed = false;
  bool _cartCollapsed = false;

  @override
  void initState() {
    super.initState();
    _menuScrollController.addListener(_onMenuScroll);
    _searchController.addListener(() {
      if (mounted) setState(() {});
    });
    PosUiPrefs.loadRailCollapsed().then((v) {
      if (mounted) setState(() => _railCollapsed = v);
    });
    PosUiPrefs.loadCartCollapsed().then((v) {
      if (mounted) setState(() => _cartCollapsed = v);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final args =
          ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
      final tableId = args?['tableId']?.toString() ?? '';
      final areaId = args?['areaId']?.toString() ?? '';

      if (tableId.isNotEmpty) {
        Provider.of<PosProvider>(
          context,
          listen: false,
        ).loadTableAndMenu(tableId, areaId);
      }
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _menuScrollController.removeListener(_onMenuScroll);
    _menuScrollController.dispose();
    _searchController.dispose();
    _cartScrollController.dispose();
    super.dispose();
  }

  void _onMenuScroll() {
    if (!_menuScrollController.hasClients) return;
    final position = _menuScrollController.position;
    if (position.pixels >= position.maxScrollExtent - 120) {
      if (_menuPage.loadMore()) {
        setState(() {});
      }
    }
  }

  void _onSearchChanged(PosProvider pos, String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      pos.setSearchQuery(value);
    });
  }

  void _clearAllFilters(PosProvider pos) {
    _searchDebounce?.cancel();
    _searchController.clear();
    pos.clearFilters();
    _menuPage.reset(
      pos.filteredMenuItems,
      fingerprint: menuFilterFingerprint(),
    );
    if (_menuScrollController.hasClients) {
      _menuScrollController.jumpTo(0);
    }
    setState(() {});
  }

  void _syncMenuPage(PosProvider pos) {
    final items = pos.filteredMenuItems;
    final fp = menuFilterFingerprint(
      categoryId: pos.selectedCategoryId,
      search: pos.searchQuery,
    );
    final previousFp = _menuPage.fingerprint;
    final changed = _menuPage.reset(items, fingerprint: fp);
    if (changed && previousFp != fp) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_menuScrollController.hasClients) {
          _menuScrollController.jumpTo(0);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pos = Provider.of<PosProvider>(context);
    final tableNum = pos.tableNumber.isEmpty ? 'Table' : pos.tableNumber;
    final tableStatus = pos.tableStatus;
    final loadFailed = pos.errorMessage != null && pos.categories.isEmpty && !pos.isLoading;
    final wideCart = MediaQuery.sizeOf(context).width >= 720;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: _buildAppBar(pos, tableNum),
      body: loadFailed
          ? _buildLoadError(pos)
          : pos.isLoading && pos.categories.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFFF97316)),
                  SizedBox(height: 16),
                  Text(
                    'Loading menu...',
                    style: TextStyle(color: Color(0xFF64748B)),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                if (pos.isBusy)
                  const LinearProgressIndicator(minHeight: 2, color: Color(0xFFF97316)),
                if (pos.cartError != null) _buildCartErrorBar(pos),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PosCategoryRail(
                        categories: pos.categories,
                        selectedCategoryId: pos.selectedCategoryId,
                        collapsed: _railCollapsed,
                        onToggleCollapsed: () {
                          setState(() => _railCollapsed = !_railCollapsed);
                          PosUiPrefs.saveRailCollapsed(_railCollapsed);
                        },
                        onSelect: (id) async {
                          pos.selectCategory(id);
                          if (id == kExtraAddonsCategoryId) {
                            await pos.ensureExtraAddonsLoaded();
                            if (!mounted) return;
                            if (pos.errorMessage ==
                                'Failed to load extra add-ons') {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(pos.errorMessage!),
                                  backgroundColor: const Color(0xFFDC2626),
                                  behavior: SnackBarBehavior.floating,
                                  margin: const EdgeInsets.fromLTRB(
                                    48,
                                    0,
                                    48,
                                    16,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                ),
                              );
                            }
                          }
                          _menuPage.reset(
                            pos.filteredMenuItems,
                            fingerprint: menuFilterFingerprint(
                              categoryId: id,
                              search: pos.searchQuery,
                            ),
                          );
                          if (_menuScrollController.hasClients) {
                            _menuScrollController.jumpTo(0);
                          }
                          if (mounted) setState(() {});
                        },
                      ),
                      const VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: Color(0xFFE2E8F0),
                      ),
                      Expanded(child: _buildMainContent(pos, tableStatus)),
                      if (wideCart) ...[
                        const VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: Color(0xFFE2E8F0),
                        ),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          width: _cartCollapsed ? 56 : 340,
                          clipBehavior: Clip.hardEdge,
                          child: _cartCollapsed
                              ? _buildCollapsedCartStrip(pos)
                              : _CartBottomSheet(
                                  pos: pos,
                                  embedded: true,
                                  onToggleCollapsed: () {
                                    setState(
                                      () => _cartCollapsed = !_cartCollapsed,
                                    );
                                    PosUiPrefs.saveCartCollapsed(
                                      _cartCollapsed,
                                    );
                                  },
                                ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
      // Phone / narrow: cart via bottom sheet. Wide: persistent right panel.
      floatingActionButton: (!wideCart && pos.cartMenuItems.isNotEmpty)
          ? FloatingActionButton.extended(
              onPressed: () => _showCartBottomSheet(context, pos),
              backgroundColor: const Color(0xFFF97316),
              icon: const Icon(Icons.shopping_cart, color: Colors.white),
              label: Text(
                '${pos.totalItemCount} items  •  ₹${pos.grandTotal.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildLoadError(PosProvider pos) {
    final expired = pos.sessionExpired;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(expired ? Icons.lock_outline : Icons.cloud_off, size: 48, color: const Color(0xFFEF4444)),
            const SizedBox(height: 12),
            Text(
              expired ? 'Session expired' : "Couldn't open this table",
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 6),
            Text(
              pos.errorMessage ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!expired) ...[
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('RETRY'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF97316),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      final tid = pos.activeTableId ?? '';
                      if (tid.isNotEmpty) pos.loadTableAndMenu(tid, pos.activeAreaId ?? '');
                    },
                  ),
                  const SizedBox(width: 12),
                ],
                OutlinedButton.icon(
                  icon: const Icon(Icons.arrow_back, size: 18),
                  label: const Text('BACK TO FLOOR'),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCartErrorBar(PosProvider pos) {
    return Material(
      color: const Color(0xFFFEF3C7),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFF92400E)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "Couldn't load this table's order: ${pos.cartError}",
                style: const TextStyle(fontSize: 11, color: Color(0xFF92400E)),
              ),
            ),
            TextButton(
              onPressed: () => pos.reloadCart(),
              child: const Text('RETRY', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(PosProvider pos, String tableNum) {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      scrolledUnderElevation: 1,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Color(0xFF0F172A)),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFF97316), Color(0xFFEA580C)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'T-$tableNum',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _searchController,
                onChanged: (v) => _onSearchChanged(pos, v),
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search food or short code...',
                  hintStyle: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF94A3B8),
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 18,
                    color: Color(0xFF94A3B8),
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _searchDebounce?.cancel();
                            _searchController.clear();
                            pos.setSearchQuery('');
                            setState(() {});
                          },
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 0,
                    horizontal: 12,
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF1F5F9),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh, color: Color(0xFF64748B), size: 22),
          onPressed: () {
            final tid = pos.activeTableId ?? '';
            final aid = pos.activeAreaId ?? '';
            if (tid.isNotEmpty) pos.loadTableAndMenu(tid, aid);
          },
          tooltip: 'Refresh',
        ),
      ],
    );
  }

  Widget _buildMainContent(PosProvider pos, String tableStatus) {
    _syncMenuPage(pos);
    final items = _menuPage.visible;
    final total = _menuPage.totalCount;
    final cartIds = pos.cartMenuIds;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  total == 0
                      ? '0 ITEMS'
                      : '${_menuPage.visibleCount} OF $total ITEMS',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: Color(0xFF64748B),
                  ),
                ),
              ),
              if (pos.hasActiveFilters)
                TextButton.icon(
                  onPressed: () => _clearAllFilters(pos),
                  icon: const Icon(Icons.filter_alt_off, size: 16),
                  label: const Text(
                    'Clear filters',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFEA580C),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty && !pos.isLoading && !pos.isExtraAddonsLoading
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.restaurant_menu,
                        size: 64,
                        color: Colors.grey.shade300,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        pos.searchQuery.isNotEmpty
                            ? 'No items found for "${pos.searchQuery}"'
                            : pos.selectedCategoryId == kFavoritesCategoryId
                                ? 'No favorite items yet'
                                : pos.selectedCategoryId ==
                                        kExtraAddonsCategoryId
                                    ? (pos.errorMessage ==
                                            'Failed to load extra add-ons'
                                        ? 'Failed to load extra add-ons — tap Extra Add-ons to retry'
                                        : 'No extra add-ons available')
                                    : 'No menu items available',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (pos.hasActiveFilters) ...[
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => _clearAllFilters(pos),
                          child: const Text('Clear filters'),
                        ),
                      ],
                    ],
                  ),
                )
              : items.isEmpty && pos.isExtraAddonsLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFFF97316),
                      ),
                    )
              : GridView.builder(
                  controller: _menuScrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(10, 6, 10, 88),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 160,
                    mainAxisExtent: 70,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemCount: items.length + (_menuPage.hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= items.length) {
                      return const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFF97316),
                          ),
                        ),
                      );
                    }
                    return _buildFoodCard(pos, items[index], cartIds);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFoodCard(
    PosProvider pos,
    MenuItem item,
    Set<String> cartIds,
  ) {
    final inCart = cartIds.contains(item.id);

    return PosMenuTile(
      key: ValueKey(item.id),
      label: item.label,
      shortCode: item.shortCode,
      attribute: item.attribute,
      inCart: inCart,
      onTap: () => _handleItemTap(pos, item),
    );
  }

  Future<void> _handleItemTap(PosProvider pos, MenuItem item) async {
    if (pos.isLoading || pos.isBusy) return;

    if (item.isCustomAddonTrigger) {
      await _showCustomExtraDialog(pos);
      return;
    }
    if (item.isExtraAddon) {
      await _showExtraAmountDialog(pos, item);
      return;
    }

    var working = item;
    // Admin opens customisable items via viewMenubyId — list payload often
    // lacks fully populated variant/addon value arrays.
    if (item.needsCustomisation || item.hasVariants || item.hasAddons || item.customisable) {
      final enriched = await pos.enrichMenuItem(item);
      if (enriched != null) working = enriched;
      if (working.hasVariants || working.hasAddons || working.customisable || item.needsCustomisation) {
        await _showItemCustomisationSheet(pos, working);
        return;
      }
    }

    await _addItemAndShowResult(pos, working);
  }

  Future<void> _showExtraAmountDialog(PosProvider pos, MenuItem item) async {
    final controller = TextEditingController(
      text: item.price > 0 ? item.price.toStringAsFixed(2) : '',
    );
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.label),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Amount (₹)',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) {
            final v = double.tryParse(controller.text.trim());
            if (v != null && v > 0) Navigator.pop(ctx, v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final v = double.tryParse(controller.text.trim());
              if (v == null || v <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Enter an amount greater than 0'),
                    backgroundColor: Color(0xFFDC2626),
                    behavior: SnackBarBehavior.floating,
                    margin: EdgeInsets.fromLTRB(48, 0, 48, 16),
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                );
                return;
              }
              Navigator.pop(ctx, v);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF97316),
              foregroundColor: Colors.white,
            ),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (amount == null || !mounted) return;
    final success = await pos.addExtraItem(name: item.label, price: amount);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Added ${item.label} ₹${amount.toStringAsFixed(2)}'
              : (pos.errorMessage ?? 'Failed to add'),
        ),
        duration: const Duration(milliseconds: 800),
        backgroundColor:
            success ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(48, 0, 48, 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _showCustomExtraDialog(PosProvider pos) async {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Do NOT use AlertDialog.scrollable:true — it binds SingleChildScrollView
        // to the modal PrimaryScrollController and can assert _dependents.isEmpty
        // on keyboard/dialog teardown. Content-only scroll with primary:false.
        title: const Text('+ Custom add-on'),
        content: SingleChildScrollView(
          primary: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: priceCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Amount (₹)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final price = double.tryParse(priceCtrl.text.trim());
              if (name.isEmpty || price == null || price <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Enter a name and amount greater than 0'),
                    backgroundColor: Color(0xFFDC2626),
                    behavior: SnackBarBehavior.floating,
                    margin: EdgeInsets.fromLTRB(48, 0, 48, 16),
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                );
                return;
              }
              Navigator.pop(ctx, true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF97316),
              foregroundColor: Colors.white,
            ),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    final name = nameCtrl.text.trim();
    final price = double.tryParse(priceCtrl.text.trim()) ?? 0;
    nameCtrl.dispose();
    priceCtrl.dispose();
    if (ok != true || !mounted) return;
    final success = await pos.addExtraItem(name: name, price: price);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Added $name ₹${price.toStringAsFixed(2)}'
              : (pos.errorMessage ?? 'Failed to add'),
        ),
        duration: const Duration(milliseconds: 800),
        backgroundColor:
            success ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(48, 0, 48, 16),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _addItemAndShowResult(
    PosProvider pos,
    MenuItem item, {
    String? variantId,
    List<Map<String, dynamic>>? addons,
  }) async {
    final success = await pos.addItemToCart(
      item,
      variantId: variantId,
      addons: addons,
    );
    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${item.displayName ?? item.name}'),
            duration: const Duration(milliseconds: 800),
            backgroundColor: const Color(0xFF16A34A),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(pos.errorMessage ?? 'Failed to add item'),
            duration: const Duration(seconds: 2),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _showItemCustomisationSheet(
    PosProvider pos,
    MenuItem item,
  ) async {
    String? selectedVariantId;
    final selectedAddons = <String, MenuAddon>{};
    bool showVariantError = false;

    double selectedTotal() {
      MenuVariant? variant;
      for (final candidate in item.variants) {
        if (candidate.id == selectedVariantId) {
          variant = candidate;
          break;
        }
      }
      final basePrice = variant?.price ?? item.price;
      final addonTotal = selectedAddons.values.fold<double>(
        0,
        (sum, addon) => sum + addon.price,
      );
      return basePrice + addonTotal;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.82,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 10),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.tune,
                            color: Color(0xFFF97316),
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1E293B),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFFE2E8F0)),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                        children: [
                          if (item.hasVariants) ...[
                            _sectionTitle('Choose Variant', required: true),
                            if (showVariantError)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 6),
                                child: Text(
                                  'Please select a variant',
                                  style: TextStyle(
                                    color: Color(0xFFDC2626),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ...item.variants.map((variant) {
                              final selected = selectedVariantId == variant.id;
                              return InkWell(
                                onTap: () {
                                  setSheetState(() {
                                    selectedVariantId = variant.id;
                                    showVariantError = false;
                                  });
                                },
                                borderRadius: BorderRadius.circular(8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        selected
                                            ? Icons.radio_button_checked
                                            : Icons.radio_button_unchecked,
                                        color: selected
                                            ? const Color(0xFFF97316)
                                            : const Color(0xFF94A3B8),
                                        size: 22,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                           () {
                                             final name = variant.name.trim();
                                             if (name.isNotEmpty &&
                                                 name.toLowerCase() != 'variant' &&
                                                 name.toLowerCase() != 'option') {
                                               return name;
                                             }
                                             final catalogName = pos.variantNameById[variant.id] ?? '';
                                             if (catalogName.isNotEmpty) return catalogName;
                                             return name.isNotEmpty ? name : 'Option';
                                           }(),
                                           style: const TextStyle(
                                             fontSize: 14,
                                             fontWeight: FontWeight.w600,
                                           ),
                                         ),
                                       ),
                                       Text(
                                         '₹${variant.price.toStringAsFixed(2)}',
                                         style: const TextStyle(
                                           color: Color(0xFFF97316),
                                           fontWeight: FontWeight.bold,
                                         ),
                                       ),
                                     ],
                                   ),
                                 ),
                               );
                             }),
                            const SizedBox(height: 8),
                          ],
                          if (item.hasAddons) ...[
                             ...() {
                               final groups = <String, List<MenuAddon>>{};
                               for (final addon in item.addons) {
                                 final gName = addon.name.isNotEmpty ? addon.name : 'Add-ons';
                                 (groups[gName] ??= []).add(addon);
                               }
                               return groups.entries.map((entry) {
                                 return Column(
                                   crossAxisAlignment: CrossAxisAlignment.start,
                                   mainAxisSize: MainAxisSize.min,
                                   children: [
                                     _sectionTitle(entry.key),
                                     ...entry.value.map((addon) {
                                       final addonKey = '${addon.addonId}:${addon.id}';
                                       final titleText = addon.valueName.isNotEmpty
                                           ? addon.valueName
                                           : (addon.name.isNotEmpty ? addon.name : 'Addon');
                                       return CheckboxListTile(
                                         value: selectedAddons.containsKey(addonKey),
                                         activeColor: const Color(0xFFF97316),
                                         contentPadding: EdgeInsets.zero,
                                         dense: true,
                                         title: Text(
                                           titleText,
                                           style: const TextStyle(
                                             fontSize: 14,
                                             fontWeight: FontWeight.w600,
                                           ),
                                         ),
                                         secondary: addon.price > 0
                                             ? Text(
                                                 '+₹${addon.price.toStringAsFixed(2)}',
                                                 style: const TextStyle(
                                                   color: Color(0xFFF97316),
                                                   fontWeight: FontWeight.bold,
                                                 ),
                                               )
                                             : null,
                                         onChanged: (checked) {
                                           setSheetState(() {
                                             if (checked == true) {
                                               selectedAddons[addonKey] = addon;
                                             } else {
                                               selectedAddons.remove(addonKey);
                                             }
                                           });
                                         },
                                       );
                                     }),
                                     const SizedBox(height: 8),
                                   ],
                                 );
                                });
                              }(),
                            ],
                          ],
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                      decoration: const BoxDecoration(
                        color: Color(0xFFFAFAFA),
                        border: Border(
                          top: BorderSide(color: Color(0xFFE2E8F0)),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Text(
                                  'Total',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                                Text(
                                  '₹${selectedTotal().toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFFF97316),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: () async {
                              if (item.hasVariants &&
                                  selectedVariantId == null) {
                                setSheetState(() => showVariantError = true);
                                return;
                              }
                              Navigator.pop(sheetContext);
                              await _addItemAndShowResult(
                                pos,
                                item,
                                variantId: selectedVariantId,
                                addons: selectedAddons.values
                                    .map((addon) => addon.toCartAddonJson())
                                    .toList(),
                              );
                            },
                            icon: const Icon(Icons.add_shopping_cart, size: 18),
                            label: const Text('ADD'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF97316),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 13,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _sectionTitle(String title, {bool required = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF0F172A),
            ),
          ),
          if (required)
            const Text(
              ' *',
              style: TextStyle(
                color: Color(0xFFDC2626),
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCollapsedCartStrip(PosProvider pos) {
    final count = pos.totalItemCount;
    return Material(
      color: Colors.white,
      child: Column(
        children: [
          const SizedBox(height: 8),
          IconButton(
            tooltip: 'Expand cart',
            onPressed: () {
              setState(() => _cartCollapsed = false);
              PosUiPrefs.saveCartCollapsed(false);
            },
            icon: const Icon(Icons.menu, color: Color(0xFF475569)),
          ),
          const SizedBox(height: 4),
          InkWell(
            onTap: () {
              setState(() => _cartCollapsed = false);
              PosUiPrefs.saveCartCollapsed(false);
            },
            child: Column(
              children: [
                Badge(
                  isLabelVisible: count > 0,
                  label: Text('$count'),
                  child: const Icon(
                    Icons.shopping_cart_outlined,
                    color: Color(0xFFF97316),
                    size: 22,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(height: 6),
                  Text(
                    '₹${pos.grandTotal.toStringAsFixed(0)}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showCartBottomSheet(BuildContext context, PosProvider pos) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CartBottomSheet(pos: pos, embedded: false),
    );
  }
}

// ============================================================
// Cart panel (bottom sheet on phone, right column on tablet)
// ============================================================

class _CartBottomSheet extends StatelessWidget {
  final PosProvider pos;
  final bool embedded;
  final VoidCallback? onToggleCollapsed;
  const _CartBottomSheet({
    required this.pos,
    this.embedded = false,
    this.onToggleCollapsed,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: pos,
      child: Consumer<PosProvider>(
        builder: (context, pos, _) {
          final items = pos.cartMenuItems;
          final cartObj = pos.cartData.isNotEmpty ? pos.cartData[0] : null;

          final header = Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Icon(
                  Icons.shopping_cart,
                  color: Color(0xFFF97316),
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Cart (${pos.totalItemCount})',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E293B),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFECE5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'T-${pos.tableDetails?['table_number'] ?? ''}',
                    style: const TextStyle(
                      color: Color(0xFFF97316),
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (onToggleCollapsed != null)
                  IconButton(
                    tooltip: 'Collapse cart',
                    onPressed: onToggleCollapsed,
                    icon: const Icon(
                      Icons.menu_open,
                      color: Color(0xFF475569),
                    ),
                  ),
              ],
            ),
          );

          Widget itemList() {
            if (items.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Cart is empty — tap menu items to add',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF94A3B8)),
                  ),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(
                height: 1,
                color: Color(0xFFF1F5F9),
              ),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: _buildCartItem(context, pos, items[i], cartObj),
              ),
            );
          }

          // Phone sheet: scroll items+footer together (keyboard safety).
          // Embedded tablet: pin totals/actions; only lines scroll.
          final Widget body;
          if (embedded) {
            body = Column(
              children: [
                Expanded(child: itemList()),
                if (items.isNotEmpty) ...[
                  const Divider(height: 1, color: Color(0xFFE2E8F0)),
                  _buildTotals(pos, cartObj),
                  _buildActionButtons(context, pos),
                ],
              ],
            );
          } else if (items.isEmpty) {
            body = itemList();
          } else {
            body = LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < items.length; i++) ...[
                              if (i > 0)
                                const Divider(
                                  height: 1,
                                  color: Color(0xFFF1F5F9),
                                ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 4,
                                ),
                                child: _buildCartItem(
                                  context,
                                  pos,
                                  items[i],
                                  cartObj,
                                ),
                              ),
                            ],
                          ],
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Divider(
                              height: 1,
                              color: Color(0xFFE2E8F0),
                            ),
                            _buildTotals(pos, cartObj),
                            _buildActionButtons(context, pos),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          }

          return Container(
            constraints: embedded
                ? null
                : BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.75,
                  ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: embedded
                  ? BorderRadius.zero
                  : const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              mainAxisSize: embedded ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (!embedded)
                  Container(
                    margin: const EdgeInsets.only(top: 10),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                header,
                const Divider(height: 1, color: Color(0xFFE2E8F0)),
                if (embedded)
                  Expanded(child: body)
                else
                  Flexible(child: body),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCartItem(
    BuildContext context,
    PosProvider pos,
    Map<String, dynamic> item,
    Map<String, dynamic>? cartObj,
  ) {
    final menuData = item['menuData'];
    final menuName = menuData is List && menuData.isNotEmpty
        ? (menuData[0]['displayname'] ?? menuData[0]['name'] ?? 'Item')
              .toString()
        : (item['menu_name'] ?? 'Item').toString();

    final variantRaw = item['variant'];
    Map<String, dynamic>? variantMap;
    if (variantRaw is Map) {
      variantMap = Map<String, dynamic>.from(variantRaw);
    } else if (variantRaw is List &&
        variantRaw.isNotEmpty &&
        variantRaw.first is Map) {
      variantMap = Map<String, dynamic>.from(variantRaw.first as Map);
    }
    final variantName = (variantMap?['valuename'] ??
            variantMap?['name'] ??
            item['variant_name'])
        ?.toString()
        .trim();

    final addonBits = <String>[];
    final addonRaw = item['addon'] ?? item['addonData'] ?? item['addons'];
    if (addonRaw is List) {
      for (final a in addonRaw) {
        if (a is! Map) continue;
        final v = a['value'];
        final label = (a['valuename'] ??
                a['value_name'] ??
                (v is Map ? (v['valuename'] ?? v['name']) : null) ??
                a['name'])
            ?.toString()
            .trim();
        if (label != null && label.isNotEmpty) addonBits.add(label);
      }
    }
    final subtitleParts = <String>[
      if (variantName != null && variantName.isNotEmpty) variantName,
      ...addonBits,
    ];

    final qty = int.tryParse(item['quantity']?.toString() ?? '1') ?? 1;
    final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
    final unitPrice =
        double.tryParse(
          item['individual_price']?.toString() ??
              item['originalPrice']?.toString() ??
              '0',
        ) ??
        (qty > 0 ? price / qty : 0);

    final cartmenuId = item['_id']?.toString() ?? '';

    final isKot = PosProvider.isKotLine(item);
    final isCancelled = item['cancel_status'] == 1;
    final note = item['description']?.toString() ?? '';

    if (isCancelled) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          // Item name
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  menuName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1E293B),
                  ),
                ),
                if (subtitleParts.isNotEmpty)
                  Text(
                    subtitleParts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF64748B),
                    ),
                  ),
                const SizedBox(height: 2),
                Text(
                  '₹${unitPrice.toStringAsFixed(2)} each',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94A3B8),
                  ),
                ),
                if (note.isNotEmpty)
                  Text(
                    'Note: $note',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontStyle: FontStyle.italic),
                  ),
                if (isKot)
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'KOT',
                      style: TextStyle(
                        fontSize: 9,
                        color: Color(0xFFD97706),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Qty controls — locked once the line is KOT'd (admin rule);
          // a KOT'd line can only be CANCELLED with a reason.
          Expanded(
            flex: 3,
            child: isKot
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'x$qty',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.cancel_outlined, size: 18, color: Color(0xFFDC2626)),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Cancel item (KOT already sent)',
                        onPressed: pos.isBusy ? null : () => _cancelKotLine(context, pos, cartmenuId, menuName),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _qtyButton(
                        icon: Icons.remove,
                        onTap: pos.isBusy
                            ? null
                            : () => _runCartWrite(
                                  context,
                                  pos,
                                  () => qty > 1
                                      ? pos.updateItemQuantity(cartmenuId, qty - 1)
                                      : pos.removeCartItem(cartmenuId),
                                ),
                      ),
                      Container(
                        constraints: const BoxConstraints(minWidth: 32),
                        alignment: Alignment.center,
                        child: Text(
                          '$qty',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ),
                      _qtyButton(
                        icon: Icons.add,
                        onTap: pos.isBusy
                            ? null
                            : () => _runCartWrite(
                                  context,
                                  pos,
                                  () => pos.updateItemQuantity(cartmenuId, qty + 1),
                                ),
                      ),
                    ],
                  ),
          ),
          // Line total
          Expanded(
            flex: 2,
            child: Text(
              '₹${price.toStringAsFixed(2)}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1E293B),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _runCartWrite(
    BuildContext context,
    PosProvider pos,
    Future<bool> Function() write,
  ) async {
    final ok = await write();
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pos.errorMessage ?? 'Could not update the order'),
          backgroundColor: const Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _cancelKotLine(
    BuildContext context,
    PosProvider pos,
    String cartmenuId,
    String itemName,
  ) async {
    final controller = TextEditingController(text: 'Removed from order');
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('KOT already sent'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Cancel "$itemName" from this order? The kitchen was already told to make it.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Reason',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep item')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
            ),
            child: const Text('Cancel item'),
          ),
        ],
      ),
    );
    if (reason == null || !context.mounted) return;
    await _runCartWrite(context, pos, () => pos.cancelKotLine(cartmenuId, reason: reason));
  }

  Widget _qtyButton({required IconData icon, required VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Icon(icon, size: 16, color: const Color(0xFF475569)),
      ),
    );
  }

  Widget _buildTotals(PosProvider pos, Map<String, dynamic>? cartObj) {
    final subTotal = pos.subTotal;
    final taxPrice = pos.taxAmount;
    final grandTotal = pos.grandTotal;
    final discountPrice =
        double.tryParse(cartObj?['discount_price']?.toString() ?? '0') ?? 0;
    final roundOff =
        double.tryParse(cartObj?['round_off']?.toString() ?? '0') ?? 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFFFAFAFA),
      child: Column(
        children: [
          _totalRow('Sub Total', '₹${subTotal.toStringAsFixed(2)}'),
          if (discountPrice > 0)
            _totalRow(
              'Discount',
              '-₹${discountPrice.toStringAsFixed(2)}',
              valueColor: const Color(0xFF16A34A),
            ),
          if (pos.containerCharge > 0)
            _totalRow('Container Charge', '₹${pos.containerCharge.toStringAsFixed(2)}'),
          if (pos.areaCharge > 0)
            _totalRow('AC / Area Charge', '₹${pos.areaCharge.toStringAsFixed(2)}'),
          if (taxPrice > 0) _totalRow('Tax', '₹${taxPrice.toStringAsFixed(2)}'),
          if (roundOff != 0)
            _totalRow('Round Off', '₹${roundOff.toStringAsFixed(2)}'),
          const Divider(height: 8, color: Color(0xFFE2E8F0)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Grand Total',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0F172A),
                ),
              ),
              Text(
                '₹${grandTotal.toStringAsFixed(2)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF97316),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _totalRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: valueColor ?? const Color(0xFF1E293B),
            ),
          ),
        ],
      ),
    );
  }

  /// Settle bill: pick payment method (+ optional discount), then settleAndPrintBill.
  Future<void> _showSettlePaymentSheet(
    BuildContext context,
    PosProvider pos,
  ) async {
    String paymentType = 'CASH'; // CASH | CARD | ONLINE (UPI → ONLINE)
    List<Map<String, dynamic>> discounts = [];
    String? selectedDiscountId;
    var discountsLoaded = false;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            if (!discountsLoaded) {
              discountsLoaded = true;
              pos.listDiscounts().then((list) {
                if (sheetContext.mounted) {
                  setSheetState(() => discounts = list);
                }
              });
            }

            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 10,
                    bottom: MediaQuery.of(context).viewInsets.bottom + 16,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Icon(
                            Icons.receipt_long,
                            color: Color(0xFFF97316),
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            pos.canRelease ? 'Settle & Release Table' : 'Print Bill & Settle',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFAFAFA),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Column(
                          children: [
                            _totalRow(
                              'Sub Total',
                              '₹${pos.subTotal.toStringAsFixed(2)}',
                            ),
                            if (pos.taxAmount > 0)
                              _totalRow(
                                'Tax',
                                '₹${pos.taxAmount.toStringAsFixed(2)}',
                              ),
                            const Divider(height: 12, color: Color(0xFFE2E8F0)),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  'Grand Total',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                Text(
                                  '₹${pos.grandTotal.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFFF97316),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (discounts.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Discount',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF475569),
                                ),
                              ),
                            ),
                            if (selectedDiscountId != null)
                              TextButton(
                                onPressed: () async {
                                  final ok = await pos.clearDiscount();
                                  if (ok) {
                                    setSheetState(
                                      () => selectedDiscountId = null,
                                    );
                                  }
                                },
                                child: const Text(
                                  'Clear',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          height: 40,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: discounts.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (_, i) {
                              final d = discounts[i];
                              final id = d['_id']?.toString() ??
                                  d['id']?.toString() ??
                                  '';
                              final name = d['title']?.toString() ??
                                  d['name']?.toString() ??
                                  d['discount_name']?.toString() ??
                                  'Discount';
                              final selected = selectedDiscountId == id;
                              return ChoiceChip(
                                label: Text(name),
                                selected: selected,
                                selectedColor: const Color(0xFFF97316),
                                labelStyle: TextStyle(
                                  color: selected
                                      ? Colors.white
                                      : Colors.black87,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                                onSelected: (_) async {
                                  final ok = await pos.applyDiscount(id);
                                  if (ok) {
                                    setSheetState(
                                      () => selectedDiscountId = id,
                                    );
                                  }
                                },
                              );
                            },
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      const Text(
                        'Payment Method',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF475569),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final option in const [
                            ('Cash', 'CASH'),
                            ('Card', 'CARD'),
                            ('UPI', 'ONLINE'),
                          ])
                            ChoiceChip(
                              label: Text(option.$1),
                              selected: paymentType == option.$2,
                              selectedColor: const Color(0xFFF97316),
                              labelStyle: TextStyle(
                                color: paymentType == option.$2
                                    ? Colors.white
                                    : Colors.black87,
                                fontWeight: FontWeight.w600,
                              ),
                              onSelected: (_) => setSheetState(
                                () => paymentType = option.$2,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      ElevatedButton.icon(
                        onPressed: () =>
                            Navigator.of(sheetContext).pop(true),
                        icon: const Icon(Icons.check, size: 18),
                        label: Text(
                          pos.canRelease ? 'Confirm & Release' : 'Print Bill & Release',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF97316),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (confirmed != true || !context.mounted) return;

    final success = await pos.settleAndPrintBill(paymentType: paymentType);
    if (!context.mounted) return;
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Table released ✓'),
          backgroundColor: Color(0xFF16A34A),
          behavior: SnackBarBehavior.floating,
        ),
      );
      // Cart no longer exists — back to the floor.
      Navigator.of(context).popUntil((r) => r.isFirst || r.settings.name == '/tables');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(pos.errorMessage ?? 'Settle failed'),
          backgroundColor: const Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _buildActionButtons(BuildContext context, PosProvider pos) {
    final busy = pos.isBusy;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: busy || !pos.hasUnprintedItems
                        ? null
                        : () async {
                            final success = await pos.sendKotOrder();
                            if (!context.mounted) return;
                            final printNote = pos.printError;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  !success
                                      ? (pos.errorMessage ?? 'KOT failed')
                                      : printNote == null
                                          ? 'KOT sent + printed ✓'
                                          : 'KOT sent to kitchen. Print failed: $printNote',
                                ),
                                backgroundColor: !success
                                    ? const Color(0xFFDC2626)
                                    : printNote == null
                                        ? const Color(0xFF16A34A)
                                        : const Color(0xFFD97706),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                    icon: const Icon(Icons.soup_kitchen, size: 18),
                    label: const Text(
                      'KOT',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            final err = await pos.printBill();
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  err == null ? 'Bill printed ✓' : err,
                                ),
                                backgroundColor: err == null
                                    ? const Color(0xFF16A34A)
                                    : const Color(0xFFDC2626),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          },
                    icon: const Icon(Icons.print, size: 18),
                    label: Text(
                      pos.tableStatus == 'PRINTED' ? 'REPRINT' : 'BILL',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C3AED),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: busy
                        ? null
                        : () => _showSettlePaymentSheet(context, pos),
                    icon: const Icon(Icons.check_circle_outline, size: 18),
                    label: const Text(
                      'SETTLE',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF97316),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: busy || pos.cartMenuItems.isEmpty
                    ? null
                    : () => _confirmDiscardCart(context, pos),
                icon: const Icon(Icons.delete_sweep, size: 18),
                label: const Text(
                  'DISCARD CART',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDC2626),
                  side: const BorderSide(color: Color(0xFFFECACA)),
                  backgroundColor: const Color(0xFFFEF2F2),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDiscardCart(
    BuildContext context,
    PosProvider pos,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this cart?'),
        content: const Text(
          'All items in this table cart will be removed. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFDC2626)),
            child: const Text('Discard Cart'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final success = await pos.discardCart();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Cart discarded'
              : (pos.errorMessage ?? 'Discard failed'),
        ),
        backgroundColor:
            success ? const Color(0xFF16A34A) : const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
      ),
    );
    if (success && context.mounted && !embedded) {
      Navigator.pop(context); // close cart sheet only (not POS when embedded)
    }
  }
}
