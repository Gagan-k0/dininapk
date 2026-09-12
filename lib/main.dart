import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/auth_provider.dart';
import 'providers/table_provider.dart';
import 'providers/pos_provider.dart';

import 'services/api_client.dart';
import 'views/auth/login_screen.dart';
import 'views/tables/dinein_table_screen.dart';
import 'views/pos/food_categories_screen.dart';
import 'views/settings/printer_settings_screen.dart';

/// Lets non-widget code (session expiry) route back to login.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FatfoxDineInApp());
}

class FatfoxDineInApp extends StatefulWidget {
  const FatfoxDineInApp({super.key});

  @override
  State<FatfoxDineInApp> createState() => _FatfoxDineInAppState();
}

class _FatfoxDineInAppState extends State<FatfoxDineInApp> {
  late final AuthProvider _auth = AuthProvider();
  late final TableProvider _tables = TableProvider();
  late final PosProvider _pos = PosProvider();

  @override
  void initState() {
    super.initState();
    _auth.checkSession();
    // A 401 anywhere → drop the session, clear floor state, back to login.
    ApiClient.onSessionExpired = (reason) async {
      await _auth.sessionExpired(reason);
      _tables.reset();
      appNavigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (_) => false);
    };
  }

  @override
  void dispose() {
    ApiClient.onSessionExpired = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _auth),
        ChangeNotifierProvider.value(value: _tables),
        ChangeNotifierProvider.value(value: _pos),
      ],
      child: Consumer<AuthProvider>(
        builder: (context, auth, _) {
          return MaterialApp(
            navigatorKey: appNavigatorKey,
            title: 'Fatfox Dine-In POS',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              colorSchemeSeed: const Color(0xFFF97316),
              // System fonts only — google_fonts downloads from fonts.gstatic.com
              // and throws on tablets with no DNS / blocked Google domains.
              scaffoldBackgroundColor: const Color(0xFFF8FAFC),
            ),
            initialRoute: auth.isLoggedIn ? '/tables' : '/login',
            routes: {
              '/login': (context) => const LoginScreen(),
              '/tables': (context) => const DineInTableScreen(),
              '/food-categories': (context) => const FoodCategoriesScreen(),
              '/settings/printer': (context) => const PrinterSettingsScreen(),
            },
          );
        },
      ),
    );
  }
}
