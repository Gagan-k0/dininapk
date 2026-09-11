import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';

import 'providers/auth_provider.dart';
import 'providers/table_provider.dart';
import 'providers/pos_provider.dart';

import 'views/auth/login_screen.dart';
import 'views/tables/dinein_table_screen.dart';
import 'views/pos/pos_ordering_screen.dart';
import 'views/pos/food_categories_screen.dart';
import 'views/settings/printer_settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FatfoxDineInApp());
}

class FatfoxDineInApp extends StatelessWidget {
  const FatfoxDineInApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()..checkSession()),
        ChangeNotifierProvider(create: (_) => TableProvider()),
        ChangeNotifierProvider(create: (_) => PosProvider()),
      ],
      child: Consumer<AuthProvider>(
        builder: (context, auth, _) {
          return MaterialApp(
            title: 'Fatfox Dine-In POS',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: const Color(0xFFF97316),
              textTheme: GoogleFonts.interTextTheme(Theme.of(context).textTheme),
              scaffoldBackgroundColor: const Color(0xFFF8FAFC),
            ),
            initialRoute: auth.isLoggedIn ? '/tables' : '/login',
            routes: {
              '/login': (context) => const LoginScreen(),
              '/tables': (context) => const DineInTableScreen(),
              '/pos': (context) => const PosOrderingScreen(),
              '/food-categories': (context) => const FoodCategoriesScreen(),
              '/settings/printer': (context) => const PrinterSettingsScreen(),
            },
          );
        },
      ),
    );
  }
}
