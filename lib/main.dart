import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/auth_provider.dart';
import 'providers/table_provider.dart';
import 'providers/pos_provider.dart';

import 'config/api_config.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/connectivity_service.dart';
import 'services/subscription_service.dart';
import 'views/auth/login_screen.dart';
import 'views/tables/dinein_table_screen.dart';
import 'views/pos/food_categories_screen.dart';
import 'views/settings/printer_settings_screen.dart';
import 'views/subscription/subscription_locked_screen.dart';

/// Lets non-widget code (session expiry) route back to login.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ConnectivityService.instance.load();
  // Any answer, even a refusal, proves the server is reachable again.
  ConnectivityService.instance.probe = () async {
    final token = await AuthService().getToken();
    if (token == null || token.isEmpty) {
      return ConnectivityService.instance.clearSignal();
    }
    await ApiClient().get(ApiConfig.getTaxConfig, background: true);
  };
  final auth = AuthProvider();
  await auth.checkSession();
  runApp(FatfoxDineInApp(authProvider: auth));
}

class FatfoxDineInApp extends StatefulWidget {
  final AuthProvider? authProvider;
  const FatfoxDineInApp({super.key, this.authProvider});

  @override
  State<FatfoxDineInApp> createState() => _FatfoxDineInAppState();
}

class _FatfoxDineInAppState extends State<FatfoxDineInApp>
    with WidgetsBindingObserver {
  late final AuthProvider _auth = widget.authProvider ?? AuthProvider();
  late final TableProvider _tables = TableProvider();
  late final PosProvider _pos = PosProvider();
  late bool _initialized = widget.authProvider != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _auth.addListener(_syncSubscription);
    _initSession();
    ConnectivityService.instance.onBackOnline = () {
      _pos.flushAllDrafts();
      SubscriptionService.instance.refresh();
    };
    // A 401 anywhere → drop the session, clear floor state, back to login.
    ApiClient.onSessionExpired = (reason) async {
      await _auth.sessionExpired(reason);
      _tables.reset();
      _pos.clearFloorDirty();
      appNavigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (_) => false);
    };
  }

  Future<void> _initSession() async {
    if (widget.authProvider == null) {
      await _auth.checkSession();
    }
    if (mounted) {
      setState(() {
        _initialized = true;
      });
    }
    _syncSubscription();
  }

  /// Restaurant the subscription check runs for; null while signed out.
  String? _subscriptionFor;

  /// Signed in (not demo) → check the subscription for that restaurant, with
  /// the login answer when there is one. Signed out → no lock on the login screen.
  void _syncSubscription() {
    final rid = _auth.isLoggedIn && !_auth.isDemoMode ? _auth.restaurantId : null;
    if (rid == _subscriptionFor) return;
    _subscriptionFor = rid;
    if (rid == null || rid.isEmpty) {
      SubscriptionService.instance.stop();
    } else {
      SubscriptionService.instance.start(
        loginSubscription: _auth.takeLoginSubscription(),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SubscriptionService.instance.refresh();
    }
  }

  Future<void> _signOutFromLock() async {
    await _auth.logout();
    _tables.reset();
    _pos.clearFloorDirty();
    appNavigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (_) => false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auth.removeListener(_syncSubscription);
    ApiClient.onSessionExpired = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFFF8FAFC),
          body: Center(
            child: CircularProgressIndicator(
              color: Color(0xFFF97316),
            ),
          ),
        ),
      );
    }

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
            // Lock gate: covers every route (the screens stay mounted, so
            // unlocking returns to where the waiter was). A route push would
            // race the login screen's own pushReplacement to /tables.
            builder: (context, child) => ListenableBuilder(
              listenable: SubscriptionService.instance,
              builder: (context, _) => Stack(
                children: [
                  child ?? const SizedBox.shrink(),
                  if (SubscriptionService.instance.isLocked)
                    Positioned.fill(
                      child: SubscriptionLockedScreen(onSignOut: _signOutFromLock),
                    ),
                ],
              ),
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
