import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dineinapk/models/receipt_customization.dart';
import 'package:dineinapk/views/settings/printer_settings_screen.dart';
import 'package:dineinapk/views/settings/receipt_preview.dart';

Future<void> _pumpAt(WidgetTester tester, Size size) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MaterialApp(home: PrinterSettingsScreen()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('landscape: preview sits beside the form, visible without scrolling',
      (tester) async {
    await _pumpAt(tester, const Size(1280, 800));

    final preview = find.byType(ReceiptPreview);
    expect(preview, findsOneWidget);
    final previewLeft = tester.getTopLeft(preview).dx;
    final connectionLeft = tester.getTopLeft(find.text('Connection Type')).dx;
    expect(previewLeft, greaterThan(connectionLeft + 400));
    expect(tester.getTopLeft(preview).dy, lessThan(800));
  });

  testWidgets('landscape: preview stays put (sticky) while the form scrolls', (tester) async {
    await _pumpAt(tester, const Size(1280, 800));
    final preview = find.byType(ReceiptPreview);
    final before = tester.getTopLeft(preview).dy;
    final connectionBefore = tester.getTopLeft(find.text('Connection Type')).dy;

    await tester.dragFrom(const Offset(300, 500), const Offset(0, -500));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('Connection Type')).dy, lessThan(connectionBefore));
    expect(tester.getTopLeft(preview).dy, before);
  });

  testWidgets('typing in a receipt text field updates the live preview', (tester) async {
    await _pumpAt(tester, const Size(1280, 800));
    final field = find.widgetWithText(TextFormField, 'Custom KOT message');
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'Serve hot');
    await tester.pump();

    expect(
      find.descendant(of: find.byType(ReceiptPreview), matching: find.text('Serve hot')),
      findsOneWidget,
    );
  });

  testWidgets('a full 80mm row stays on one line in a narrow panel with theme letter spacing',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(textTheme: const TextTheme(bodyMedium: TextStyle(letterSpacing: 0.5))),
      home: const Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: ReceiptPreview(c: ReceiptCustomization.defaults, isKot: true, charsPerLine: 48),
          ),
        ),
      ),
    ));
    final row = tester.getSize(find.textContaining('Paneer Butter Masala'));
    final single = tester.getSize(find.text('Table #: 5'));
    expect(row.height, single.height); // wrapped rows are twice as tall
  });

  testWidgets('portrait phone: preview stays stacked under the form', (tester) async {
    await _pumpAt(tester, const Size(400, 800));

    final preview = find.byType(ReceiptPreview);
    expect(preview, findsOneWidget);
    expect(
      tester.getTopLeft(preview).dx,
      moreOrLessEquals(tester.getTopLeft(find.text('Connection Type')).dx, epsilon: 1),
    );
  });
}
