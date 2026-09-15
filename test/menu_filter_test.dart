import 'package:flutter_test/flutter_test.dart';

import 'package:dineinapk/models/menu_model.dart';
import 'package:dineinapk/utils/menu_filter.dart';

MenuItem _item({
  required String name,
  String? displayName,
  String categoryId = '',
  List<String> categoryNames = const [],
}) {
  return MenuItem(
    id: name,
    categoryId: categoryId,
    categoryNames: categoryNames,
    name: name,
    displayName: displayName,
    attribute: 'VEG',
    price: 10,
  );
}

void main() {
  group('flattenCategoryNames', () {
    test('flattens nested by-category-itemin shape', () {
      expect(
        flattenCategoryNames([
          [
            {'name': 'Starters', 'status': 1},
          ],
        ]),
        ['Starters'],
      );
      expect(
        flattenCategoryNames([
          {'name': 'Mains'},
        ]),
        ['Mains'],
      );
    });
  });

  group('filterMenuItems', () {
    final items = [
      _item(name: 'Soup', categoryNames: ['Starters']),
      _item(name: 'Biryani', categoryNames: ['Mains']),
      _item(
        name: 'Draft',
        categoryId: 'cat-1',
        categoryNames: const [],
      ),
    ];

    test('ALL shows every item', () {
      expect(filterMenuItems(items: items), hasLength(3));
    });

    test('matches by category name ignoring case', () {
      final out = filterMenuItems(
        items: items,
        categoryNames: ['starters', 'Starters'],
      );
      expect(out.map((e) => e.name), ['Soup']);
    });

    test('matches by category id when names missing', () {
      final out = filterMenuItems(
        items: items,
        categoryId: 'cat-1',
      );
      expect(out.map((e) => e.name), ['Draft']);
    });

    test('search filters by name', () {
      final out = filterMenuItems(items: items, search: 'bir');
      expect(out.map((e) => e.name), ['Biryani']);
    });
  });

  group('MenuCategory.fromJson', () {
    test('uses valuename/displayname from active-all', () {
      final cat = MenuCategory.fromJson({
        '_id': '1',
        'valuename': 'starters',
        'displayname': 'Starters',
      });
      expect(cat.categoryName, 'Starters');
      expect(cat.filterNames, containsAll(['starters', 'Starters']));
    });
  });

  group('MenuItem.fromJson', () {
    test('parses nested category names', () {
      final item = MenuItem.fromJson({
        '_id': 'm1',
        'name': 'Soup',
        'displayname': '',
        'attribute': 'VEG',
        'price': 50,
        'category': [
          [
            {'name': 'Starters', 'status': 1},
          ],
        ],
      });
      expect(item.categoryNames, ['Starters']);
      expect(item.categoryId, '');
      expect(item.label, 'Soup');
    });
  });
}
