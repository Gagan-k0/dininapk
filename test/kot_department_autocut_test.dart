import 'package:flutter_test/flutter_test.dart';
import 'package:dineinapk/models/menu_model.dart';
import 'package:dineinapk/models/cart_model.dart';
import 'package:dineinapk/models/table_model.dart';
import 'package:dineinapk/models/receipt_customization.dart';
import 'package:dineinapk/providers/pos_provider.dart';
import 'package:dineinapk/services/thermal_printer_service.dart';
import 'package:esc_pos_utils/esc_pos_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Category & Kitchen Department KOT Autocut Tests', () {
    test('parseDepartments parses raw list of strings or ObjectIDs correctly', () {
      final list = ['dept_1', {'_id': 'dept_2', 'name': 'South Indian'}, null, 'dept_1'];
      final depts = parseDepartments(list);
      expect(depts, equals(['dept_1', 'dept_2']));
    });

    test('MenuCategory and MenuItem parse departments from JSON', () {
      final catJson = {
        '_id': 'cat_100',
        'valuename': 'Main Course',
        'departments': ['dept_north', 'dept_south']
      };
      final category = MenuCategory.fromJson(catJson);
      expect(category.departments, equals(['dept_north', 'dept_south']));

      final itemJson = {
        '_id': 'item_101',
        'category_id': 'cat_100',
        'name': 'Paneer Butter Masala',
        'price': 250,
        'departments': [{'id': 'dept_north'}]
      };
      final item = MenuItem.fromJson(itemJson);
      expect(item.departments, equals(['dept_north']));
    });

    test('PosProvider builds per-department KOT groups and sorts General last', () {
      final provider = PosProvider();
      provider.populateKitchenDepartments([
        {'_id': 'd1', 'name': 'North Indian', 'sort_order': 1},
        {'_id': 'd2', 'name': 'Beverages', 'sort_order': 2},
      ]);

      final itemNorth = CartLineItem(
        id: 'c1',
        item: MenuItem(
          id: 'i1',
          categoryId: 'cat1',
          name: 'Butter Naan',
          attribute: 'VEG',
          price: 40,
          departments: ['d1'],
        ),
      );

      final itemDrink = CartLineItem(
        id: 'c2',
        item: MenuItem(
          id: 'i2',
          categoryId: 'cat2',
          name: 'Mango Lassi',
          attribute: 'VEG',
          price: 80,
          departments: ['d2'],
        ),
      );

      final itemUnassigned = CartLineItem(
        id: 'c3',
        item: MenuItem(
          id: 'i3',
          categoryId: 'cat3',
          name: 'Custom Salad',
          attribute: 'VEG',
          price: 100,
          departments: [],
        ),
      );

      final groups = provider.buildKotGroups([itemNorth, itemDrink, itemUnassigned]);
      expect(groups.length, equals(3));
      expect(groups[0].name, equals('North Indian'));
      expect(groups[0].items.map((i) => i.item.name), equals(['Butter Naan']));
      expect(groups[1].name, equals('Beverages'));
      expect(groups[1].items.map((i) => i.item.name), equals(['Mango Lassi']));
      expect(groups[2].name, equals('General'));
      expect(groups[2].items.map((i) => i.item.name), equals(['Custom Salad']));
    });

    test('Multi-department item appears in each assigned department KOT ticket', () {
      final provider = PosProvider();
      provider.populateKitchenDepartments([
        {'_id': 'd1', 'name': 'North Indian', 'sort_order': 1},
        {'_id': 'd2', 'name': 'Tandoor', 'sort_order': 2},
      ]);

      final comboItem = CartLineItem(
        id: 'c1',
        item: MenuItem(
          id: 'i1',
          categoryId: 'cat1',
          name: 'Tandoori Platter',
          attribute: 'NONVEG',
          price: 450,
          departments: ['d1', 'd2'],
        ),
      );

      final groups = provider.buildKotGroups([comboItem]);
      expect(groups.length, equals(2));
      expect(groups[0].name, equals('North Indian'));
      expect(groups[0].items.first.item.name, equals('Tandoori Platter'));
      expect(groups[1].name, equals('Tandoor'));
      expect(groups[1].items.first.item.name, equals('Tandoori Platter'));
    });

    test('ThermalPrinterService generates separate ESC/POS ticket bytes with department name and autocut per group', () async {
      final service = ThermalPrinterService();
      final table = DineInTable(
        id: 't1',
        tableNumber: 'Table 5',
        areaId: 'a1',
        noOfPeople: 4,
        tableStatus: 'KOT',
        status: '1',
        totalPrice: 200,
        itemCount: 1,
      );

      final item = CartLineItem(
        id: 'c1',
        item: MenuItem(
          id: 'i1',
          categoryId: 'cat1',
          name: 'Dal Makhani',
          attribute: 'VEG',
          price: 200,
        ),
        quantity: 1,
      );

      final customization = ReceiptCustomization.defaults.copyWith(
        kotShowDepartmentName: true,
      );

      final bytes = await service.generateKotBytes(
        table: table,
        items: [item],
        restaurantName: 'FatFox Bistro',
        paperSize: PaperSize.mm80,
        department: 'North Indian',
        customization: customization,
      );

      expect(bytes, isNotEmpty);
      final text = String.fromCharCodes(bytes);
      expect(text, contains('DEPARTMENT : North Indian'));
      expect(text, contains('Dal Makhani'));
      // Verify ESC/POS cut command (GS V => 29, 86) is present at ticket end
      expect(bytes, containsAllInOrder([29, 86]));
    });
  });
}
