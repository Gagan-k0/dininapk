import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/pos_provider.dart';
import '../../providers/table_provider.dart';
import '../../providers/auth_provider.dart';
import '../../models/menu_model.dart';
import '../../models/cart_model.dart';
import '../../services/thermal_printer_service.dart';

class PosOrderingScreen extends StatelessWidget {
  const PosOrderingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final pos = Provider.of<PosProvider>(context);
    final auth = Provider.of<AuthProvider>(context);
    final table = pos.activeTable;

    if (table == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('No active table selected'),
              ElevatedButton(
                onPressed: () => Navigator.pushReplacementNamed(context, '/tables'),
                child: const Text('Back to Tables'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF0F172A)),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFFFECE5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Table ${table.tableNumber}',
                style: const TextStyle(color: Color(0xFFF97316), fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 40,
                child: TextField(
                  onChanged: (v) => pos.setSearchQuery(v),
                  decoration: InputDecoration(
                    hintText: 'Search food item or short code...',
                    hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
                    prefixIcon: const Icon(Icons.search, size: 20, color: Color(0xFF94A3B8)),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
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
      ),
      body: Row(
        children: [
          // Left Sidebar: Categories List
          Container(
            width: 180,
            color: Colors.white,
            child: ListView(
              children: [
                _buildCategoryTile(pos, null, 'ALL ITEMS'),
                ...pos.categories.map((cat) => _buildCategoryTile(pos, cat.id, cat.categoryName)),
              ],
            ),
          ),
          const VerticalDivider(width: 1, color: Color(0xFFE2E8F0)),

          // Center: Food Menu Items Grid
          Expanded(
            child: pos.isLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFFF97316)))
                : pos.filteredMenuItems.isEmpty
                    ? const Center(child: Text('No food items found', style: TextStyle(color: Color(0xFF64748B))))
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: GridView.builder(
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 160,
                            childAspectRatio: 1.0,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                          itemCount: pos.filteredMenuItems.length,
                          itemBuilder: (context, index) {
                            final item = pos.filteredMenuItems[index];
                            return _buildMenuItemCard(context, pos, item);
                          },
                        ),
                      ),
          ),
          const VerticalDivider(width: 1, color: Color(0xFFE2E8F0)),

          // Right Sidebar: Active Cart & Bill Summary Panel
          Container(
            width: 340,
            color: Colors.white,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: const BoxDecoration(
                    color: Color(0xFFF8FAFC),
                    border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('ORDER CART', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A))),
                      Text('${pos.totalItemCount} Items', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                    ],
                  ),
                ),

                // Cart Line Items List
                Expanded(
                  child: pos.cartLines.isEmpty
                      ? const Center(child: Text('Cart is empty. Tap items to order.', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12)))
                      : ListView.separated(
                          itemCount: pos.cartLines.length,
                          separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFFF1F5F9)),
                          itemBuilder: (context, index) {
                            final line = pos.cartLines[index];
                            return _buildCartLineTile(pos, line);
                          },
                        ),
                ),

                // Bill Summary & Action Buttons
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(color: Colors.black12, blurRadius: 10, offset: Offset(0, -2)),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Subtotal', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
                          Text('₹${pos.subTotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('GST (5%)', style: TextStyle(color: Color(0xFF64748B), fontSize: 13)),
                          Text('₹${pos.taxAmount.toStringAsFixed(2)}', style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
                        ],
                      ),
                      const Divider(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('TOTAL PAYABLE', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF0F172A))),
                          Text('₹${pos.grandTotal.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFFF97316))),
                        ],
                      ),
                      const SizedBox(height: 12),

                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 44,
                              child: ElevatedButton.icon(
                                icon: const Icon(Icons.send, size: 16),
                                label: const Text('KOT', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFF97316),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  elevation: 0,
                                ),
                                onPressed: pos.cartLines.isEmpty || pos.isLoading
                                    ? null
                                    : () async {
                                        final success = await pos.sendKot();
                                        if (success && context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('KOT sent to kitchen successfully!'), backgroundColor: Colors.green),
                                          );
                                        }
                                      },
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SizedBox(
                              height: 44,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.print, size: 16),
                                label: const Text('BILL', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF0F172A),
                                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                onPressed: pos.cartLines.isEmpty
                                    ? null
                                    : () async {
                                        final printerService = ThermalPrinterService();
                                        final paperConfig = pos.printerSettings['paper_size']?.toString() ?? '80mm';
                                        try {
                                          final bytes = await printerService.generateBillBytes(
                                            table: table,
                                            items: pos.cartLines,
                                            subTotal: pos.subTotal,
                                            taxAmount: pos.taxAmount,
                                            grandTotal: pos.grandTotal,
                                            restaurantName: pos.printerSettings['header_title']?.toString() ?? auth.restaurantName,
                                            paperSize: paperConfig,
                                          );
                                          await printerService.printBytes(bytes);
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('Receipt sent to thermal printer'),
                                                backgroundColor: Color(0xFF2563EB),
                                              ),
                                            );
                                          }
                                        } catch (e) {
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              SnackBar(
                                                content: Text(
                                                  e.toString().replaceAll('Exception: ', ''),
                                                ),
                                                backgroundColor: const Color(0xFFEF4444),
                                              ),
                                            );
                                          }
                                        }
                                      },
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        height: 40,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.check_circle_outline, size: 16),
                          label: const Text('SETTLE & RELEASE TABLE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF16A34A),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () async {
                            final tableProv = Provider.of<TableProvider>(context, listen: false);
                            final success = await tableProv.releaseTable(table.id);
                            if (success && context.mounted) {
                              pos.clearCart();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Table released successfully!'), backgroundColor: Colors.green),
                              );
                              Navigator.pop(context);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryTile(PosProvider pos, String? catId, String name) {
    final isSelected = pos.selectedCategoryId == catId;
    return InkWell(
      onTap: () => pos.selectCategory(catId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFECE5) : Colors.transparent,
          border: Border(left: BorderSide(color: isSelected ? const Color(0xFFF97316) : Colors.transparent, width: 4)),
        ),
        child: Text(
          name,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? const Color(0xFFF97316) : const Color(0xFF475569),
          ),
        ),
      ),
    );
  }

  Widget _buildMenuItemCard(BuildContext context, PosProvider pos, MenuItem item) {
    final isVeg = item.attribute == 'VEG';
    final dotColor = isVeg ? Colors.green : Colors.red;

    return InkWell(
      onTap: () => pos.addToCart(item),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: dotColor, width: 1.5),
                  ),
                  child: Center(
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (item.shortCode != null && item.shortCode!.isNotEmpty)
                  Text(
                    '${item.shortCode}',
                    style: const TextStyle(fontSize: 9, color: Color(0xFF94A3B8)),
                  ),
              ],
            ),
            Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '₹${item.price.toStringAsFixed(0)}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFF97316)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF97316),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('+ ADD', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCartLineTile(PosProvider pos, CartLineItem line) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.item.name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                Text('₹${line.unitPrice.toStringAsFixed(0)}', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
              ],
            ),
          ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline, size: 20, color: Color(0xFFEF4444)),
                onPressed: () => pos.updateQuantity(line, line.quantity - 1),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('${line.quantity}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 20, color: Color(0xFF22C55E)),
                onPressed: () => pos.updateQuantity(line, line.quantity + 1),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
