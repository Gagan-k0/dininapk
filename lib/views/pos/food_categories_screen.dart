import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/pos_provider.dart';
import '../../models/menu_model.dart';

class FoodCategoriesScreen extends StatefulWidget {
  const FoodCategoriesScreen({super.key});

  @override
  State<FoodCategoriesScreen> createState() => _FoodCategoriesScreenState();
}

class _FoodCategoriesScreenState extends State<FoodCategoriesScreen> {
  bool _initialized = false;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _cartScrollController = ScrollController();

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
    _searchController.dispose();
    _cartScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pos = Provider.of<PosProvider>(context);
    final tableNum = pos.tableDetails?['table_number']?.toString() ?? 'Table';
    final tableStatus = pos.tableDetails?['table_status']?.toString() ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: _buildAppBar(pos, tableNum),
      body: pos.isLoading && pos.categories.isEmpty
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
                // Category horizontal scroll bar
                _buildCategoryBar(pos),
                const Divider(height: 1, color: Color(0xFFE2E8F0)),
                // Menu grid + Cart panel
                Expanded(child: _buildMainContent(pos, tableStatus)),
              ],
            ),
      // Cart FAB showing item count
      floatingActionButton: pos.cartMenuItems.isNotEmpty
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
                onChanged: (v) => pos.setSearchQuery(v),
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
                          icon: const Icon(Icons.close, size: 16),
                          onPressed: () {
                            _searchController.clear();
                            pos.setSearchQuery('');
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

  Widget _buildCategoryBar(PosProvider pos) {
    return Container(
      height: 50,
      color: Colors.white,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: pos.categories.length + 1, // +1 for "ALL"
        itemBuilder: (context, index) {
          final isAll = index == 0;
          final isSelected = isAll
              ? pos.selectedCategoryId == null
              : pos.selectedCategoryId == pos.categories[index - 1].id;
          final label = isAll ? 'ALL' : pos.categories[index - 1].categoryName;

          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: GestureDetector(
              onTap: () {
                if (isAll) {
                  pos.selectCategory(null);
                } else {
                  pos.selectCategory(pos.categories[index - 1].id);
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFFF97316)
                      : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFFF97316)
                        : const Color(0xFFE2E8F0),
                    width: 1,
                  ),
                ),
                child: Center(
                  child: Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? Colors.white
                          : const Color(0xFF475569),
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMainContent(PosProvider pos, String tableStatus) {
    final items = pos.filteredMenuItems;

    if (items.isEmpty && !pos.isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.restaurant_menu, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text(
              pos.searchQuery.isNotEmpty
                  ? 'No items found for "${pos.searchQuery}"'
                  : 'No menu items available',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.15,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => _buildFoodCard(pos, items[index]),
    );
  }

  Widget _buildFoodCard(PosProvider pos, MenuItem item) {
    final isNonVeg = item.attribute.toUpperCase() == 'NONVEG';
    final isEgg = item.attribute.toUpperCase() == 'EGG';

    Color attrColor = const Color(0xFF16A34A); // green default
    if (isNonVeg) attrColor = const Color(0xFFDC2626);
    if (isEgg) attrColor = const Color(0xFFD97706);

    final displayName = item.displayName ?? item.name;
    final hasImage =
        item.image != null && item.image!.isNotEmpty && item.image != 'null';

    // Check if item is already in cart
    final inCart = pos.cartMenuItems.any((ci) {
      final menuData = ci['menuData'];
      if (menuData is List && menuData.isNotEmpty) {
        return menuData[0]['_id']?.toString() == item.id ||
            menuData[0]['name']?.toString() == item.name;
      }
      return false;
    });

    return GestureDetector(
      onTap: () => _handleItemTap(pos, item),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: inCart ? const Color(0xFFFFF7ED) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: inCart ? const Color(0xFFFDBA74) : const Color(0xFFE2E8F0),
            width: inCart ? 1.5 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image or placeholder
            Expanded(
              flex: 3,
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(13),
                  ),
                  image: hasImage
                      ? DecorationImage(
                          image: NetworkImage(item.image!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: hasImage
                    ? null
                    : Center(
                        child: Icon(
                          Icons.restaurant,
                          size: 32,
                          color: Colors.grey.shade300,
                        ),
                      ),
              ),
            ),
            // Item details
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // VEG/NONVEG indicator + name
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 2, right: 4),
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            border: Border.all(color: attrColor, width: 1.5),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Center(
                            child: Container(
                              width: 7,
                              height: 7,
                              decoration: BoxDecoration(
                                color: attrColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1E293B),
                              height: 1.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Short code + Price
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (item.shortCode != null &&
                            item.shortCode!.isNotEmpty)
                          Text(
                            item.shortCode!,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF94A3B8),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF97316)
                                .withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '₹${item.price.toStringAsFixed(0)}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFFF97316),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleItemTap(PosProvider pos, MenuItem item) async {
    if (pos.isLoading) return;

    if (item.hasVariants || item.hasAddons) {
      await _showItemCustomisationSheet(pos, item);
      return;
    }

    await _addItemAndShowResult(pos, item);
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
                              item.displayName ?? item.name,
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
                                          variant.name.isNotEmpty
                                              ? variant.name
                                              : 'Variant',
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
                            _sectionTitle('Add-ons'),
                            ...item.addons.map((addon) {
                              final addonKey = '${addon.addonId}:${addon.id}';
                              return CheckboxListTile(
                                value: selectedAddons.containsKey(addonKey),
                                activeColor: const Color(0xFFF97316),
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: Text(
                                  addon.valueName.isNotEmpty
                                      ? addon.valueName
                                      : addon.name,
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

  void _showCartBottomSheet(BuildContext context, PosProvider pos) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CartBottomSheet(pos: pos),
    );
  }
}

// ============================================================
// Cart Bottom Sheet
// ============================================================

class _CartBottomSheet extends StatelessWidget {
  final PosProvider pos;
  const _CartBottomSheet({required this.pos});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: pos,
      child: Consumer<PosProvider>(
        builder: (context, pos, _) {
          final items = pos.cartMenuItems;
          final cartObj = pos.cartData.isNotEmpty ? pos.cartData[0] : null;

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.75,
            ),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.shopping_cart,
                            color: Color(0xFFF97316),
                            size: 22,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Cart (${pos.totalItemCount} items)',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1E293B),
                            ),
                          ),
                        ],
                      ),
                      // Table badge
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
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFFE2E8F0)),

                // Cart items list
                Flexible(
                  child: items.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(32),
                          child: Text(
                            'Cart is empty',
                            style: TextStyle(color: Color(0xFF94A3B8)),
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          itemCount: items.length,
                          separatorBuilder: (_, index) => const Divider(
                            height: 1,
                            color: Color(0xFFF1F5F9),
                          ),
                          itemBuilder: (ctx, i) =>
                              _buildCartItem(ctx, pos, items[i], cartObj),
                        ),
                ),

                // Totals + Actions
                if (items.isNotEmpty) ...[
                  const Divider(height: 1, color: Color(0xFFE2E8F0)),
                  _buildTotals(pos, cartObj),
                  _buildActionButtons(context, pos),
                ],
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

    final qty = int.tryParse(item['quantity']?.toString() ?? '1') ?? 1;
    final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
    final unitPrice =
        double.tryParse(
          item['individual_price']?.toString() ??
              item['originalPrice']?.toString() ??
              '0',
        ) ??
        (qty > 0 ? price / qty : 0);

    final cartItemId = cartObj?['_id']?.toString() ?? '';
    final cartmenuId = item['_id']?.toString() ?? '';

    final isKot = item['kot_status'] == 1 || item['kotprint_status'] == 1;
    final isCancelled = item['cancel_status'] == 1;

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
                const SizedBox(height: 2),
                Text(
                  '₹${unitPrice.toStringAsFixed(2)} each',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94A3B8),
                  ),
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
          // Qty controls
          Expanded(
            flex: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _qtyButton(
                  icon: Icons.remove,
                  onTap: () async {
                    if (qty > 1) {
                      await pos.updateItemQuantity(
                        cartItemId,
                        cartmenuId,
                        qty - 1,
                      );
                    } else {
                      await pos.removeCartItem(cartItemId, cartmenuId);
                    }
                  },
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
                  onTap: () async {
                    await pos.updateItemQuantity(
                      cartItemId,
                      cartmenuId,
                      qty + 1,
                    );
                  },
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

  Widget _qtyButton({required IconData icon, required VoidCallback onTap}) {
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
                      const Row(
                        children: [
                          Icon(
                            Icons.receipt_long,
                            color: Color(0xFFF97316),
                            size: 22,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Settle & Print Bill',
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
                        label: const Text(
                          'Confirm & Print',
                          style: TextStyle(
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
      final printNote = pos.printError;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            printNote == null
                ? 'Bill settled + printed ✓'
                : 'Bill settled. Print failed: $printNote',
          ),
          backgroundColor: printNote == null
              ? const Color(0xFF16A34A)
              : const Color(0xFFD97706),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: pos.isLoading
                    ? null
                    : () async {
                        final success = await pos.sendKotOrder();
                        if (!context.mounted) return;
                        if (success) {
                          final printNote = pos.printError;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                printNote == null
                                    ? 'KOT sent + printed ✓'
                                    : 'KOT sent to kitchen. Print failed: $printNote',
                              ),
                              backgroundColor: printNote == null
                                  ? const Color(0xFF16A34A)
                                  : const Color(0xFFD97706),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(pos.errorMessage ?? 'KOT failed'),
                              backgroundColor: const Color(0xFFDC2626),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.print, size: 18),
                label: const Text(
                  'KOT PRINT',
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
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: pos.isLoading
                    ? null
                    : () => _showSettlePaymentSheet(context, pos),
                icon: const Icon(Icons.receipt_long, size: 18),
                label: const Text(
                  'SAVE & PRINT',
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
      ),
    );
  }
}
