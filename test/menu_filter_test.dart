import 'package:flutter_test/flutter_test.dart';

import 'package:dineinapk/models/menu_model.dart';
import 'package:dineinapk/utils/menu_filter.dart';
import 'package:dineinapk/utils/menu_page_window.dart';

MenuItem _item({
  required String name,
  String? displayName,
  String categoryId = '',
  List<String> categoryNames = const [],
  String? shortCode,
}) {
  return MenuItem(
    id: name,
    categoryId: categoryId,
    categoryNames: categoryNames,
    name: name,
    displayName: displayName,
    shortCode: shortCode,
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

    test('search filters by label and short code', () {
      final out = filterMenuItems(items: items, search: 'bir');
      expect(out.map((e) => e.name), ['Biryani']);
      final byCode = filterMenuItems(
        items: [
          _item(name: 'X', displayName: 'Hidden', shortCode: 'MD1'),
        ],
        search: 'md1',
      );
      expect(byCode.single.shortCode, 'MD1');
    });

    test('alreadySorted skips reordering', () {
      final unsorted = [
        _item(name: 'Zed'),
        _item(name: 'Able'),
      ];
      final kept = filterMenuItems(items: unsorted, alreadySorted: true);
      expect(kept.map((e) => e.name), ['Zed', 'Able']);
    });
  });

  group('menuFilterFingerprint', () {
    test('changes with category or search', () {
      expect(menuFilterFingerprint(), '|');
      expect(
        menuFilterFingerprint(categoryId: 'c1', search: ' Soup '),
        'c1|soup',
      );
      expect(
        menuFilterFingerprint(categoryId: 'c1'),
        isNot(menuFilterFingerprint(categoryId: 'c2')),
      );
    });
  });

  group('MenuPageWindow', () {
    test('resets only when fingerprint changes', () {
      final page = MenuPageWindow<int>(pageSize: 3);
      expect(page.reset([1, 2, 3, 4], fingerprint: 'a'), isTrue);
      expect(page.visible, [1, 2, 3]);
      expect(page.reset([1, 2, 3, 4], fingerprint: 'a'), isFalse);
      expect(page.loadMore(), isTrue);
      expect(page.visible, [1, 2, 3, 4]);
      expect(page.reset([9, 8, 7], fingerprint: 'b'), isTrue);
      expect(page.visible, [9, 8, 7]);
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

    test('label prefers displayname then name; never blank', () {
      expect(
        MenuItem.fromJson({
          '_id': 'm2',
          'name': '',
          'displayname': '  Masala Dosa  ',
          'attribute': 'VEG',
          'price': 80,
        }).label,
        'Masala Dosa',
      );
      expect(
        MenuItem.fromJson({
          '_id': 'm3',
          'name': '   ',
          'displayname': '',
          'shortCode': 'MD1',
          'attribute': 'VEG',
          'price': 80,
        }).label,
        'MD1',
      );
      expect(_item(name: '', displayName: '').label, 'Item');
    });
  });
}
