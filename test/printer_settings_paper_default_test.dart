import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dineinapk/views/settings/printer_settings_screen.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: PrinterSettingsScreen()),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'fresh install: selecting Bluetooth defaults Paper Size to 58mm',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pump(tester);

      // Fresh default is 80mm (LAN default) until Bluetooth is chosen.
      expect(find.widgetWithText(ChoiceChip, '80mm'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Bluetooth'));
      await tester.pumpAndSettle();

      final selected58 = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '58mm'),
      );
      expect(selected58.selected, isTrue);
    },
  );

  testWidgets(
    'fresh install: switching back to LAN restores 80mm default',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pump(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Bluetooth'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'LAN'));
      await tester.pumpAndSettle();

      final selected80 = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '80mm'),
      );
      expect(selected80.selected, isTrue);
    },
  );

  testWidgets(
    'an explicit Paper Size choice survives switching Connection Type',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pump(tester);

      // User explicitly picks 80mm for Bluetooth (a real 80mm BT printer).
      await tester.tap(find.widgetWithText(ChoiceChip, 'Bluetooth'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '80mm'));
      await tester.pumpAndSettle();

      // Switching away and back must not silently revert their choice.
      await tester.tap(find.widgetWithText(ChoiceChip, 'LAN'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Bluetooth'));
      await tester.pumpAndSettle();

      final stillSelected80 = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '80mm'),
      );
      expect(stillSelected80.selected, isTrue);
    },
  );

  testWidgets(
    'Save marks the current paper size explicit immediately, before any reload',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pump(tester);

      // Bluetooth auto-defaults to 58mm (not yet explicit).
      await tester.tap(find.widgetWithText(ChoiceChip, 'Bluetooth'));
      await tester.pumpAndSettle();
      // Save while still on this screen instance (no reload in between).
      final saveButton = find.widgetWithText(ElevatedButton, 'Save Printer Settings');
      await tester.ensureVisible(saveButton);
      await tester.pumpAndSettle();
      await tester.tap(saveButton, warnIfMissed: false);
      await tester.pumpAndSettle();

      // Switching to LAN and back must not silently revert the saved 58mm.
      final lanChip = find.widgetWithText(ChoiceChip, 'LAN');
      await tester.ensureVisible(lanChip);
      await tester.pumpAndSettle();
      await tester.tap(lanChip);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Bluetooth'));
      await tester.pumpAndSettle();

      final still58 = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '58mm'),
      );
      expect(still58.selected, isTrue);
    },
  );

  testWidgets(
    'saving only a printer change succeeds without the admin-only settings API',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await _pump(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Bluetooth'));
      await tester.pumpAndSettle();
      final saveButton = find.widgetWithText(ElevatedButton, 'Save Printer Settings');
      await tester.ensureVisible(saveButton);
      await tester.pumpAndSettle();
      await tester.tap(saveButton, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('Printer settings saved successfully!'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('printer_type'), 'Bluetooth');
    },
  );

  testWidgets(
    'a previously saved paper size is never overridden by the smart default',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'printer_type': 'LAN',
        'printer_paper': '80mm',
      });
      await _pump(tester);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Bluetooth'));
      await tester.pumpAndSettle();

      final still80 = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '80mm'),
      );
      expect(still80.selected, isTrue);
    },
  );
}
