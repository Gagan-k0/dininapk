import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dineinapk/widgets/pos_menu_tile.dart';

void main() {
  testWidgets('PosMenuTile paints label on white panel in grid-sized cell', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GridView(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 160,
              mainAxisExtent: 70,
            ),
            children: [
              PosMenuTile(
                label: 'Masala Dosa',
                attribute: 'VEG',
                inCart: false,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Masala Dosa'), findsOneWidget);
    final text = tester.widget<Text>(find.text('Masala Dosa'));
    expect(text.style?.color, const Color(0xFF0F172A));
  });
}
