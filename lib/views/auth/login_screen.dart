import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  // Empty by default — enter real restaurant/staff credentials.
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _restaurantNoController = TextEditingController();
  final _urlController = TextEditingController(
    text: 'https://backend.fatfox.testfox.in/api/v1',
  );
  bool _obscure = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _restaurantNoController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _goTables(AuthProvider auth, Future<bool> Function() action) async {
    final nav = Navigator.of(context);
    final success = await action();
    if (success && mounted) {
      nav.pushReplacementNamed('/tables');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            width: 420,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFECE5),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.table_restaurant,
                      size: 40,
                      color: Color(0xFFF97316),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'DINE-IN POS TERMINAL',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Use the same restaurant username/password as the admin panel.\n'
                    'Staff users also need Restaurant No.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 24),

                  if (auth.errorMessage != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        border: Border.all(color: const Color(0xFFFCA5A5)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        auth.errorMessage!,
                        style: const TextStyle(
                          color: Color(0xFF991B1B),
                          fontSize: 13,
                        ),
                      ),
                    ),

                  TextFormField(
                    controller: _emailController,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'Restaurant / Staff Username',
                      helperText: 'Same username as admin panel login',
                      prefixIcon: const Icon(Icons.badge_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required field' : null,
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required field' : null,
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _restaurantNoController,
                    textInputAction: TextInputAction.next,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Restaurant No. (staff only)',
                      helperText:
                          'Leave blank for restaurant-owner login. Required for staff.',
                      prefixIcon: const Icon(Icons.storefront_outlined),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _urlController,
                    decoration: InputDecoration(
                      labelText: 'Server API Base URL',
                      prefixIcon: const Icon(Icons.dns_outlined),
                      helperText:
                          'Default: https://backend.fatfox.testfox.in/api/v1',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),

                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: auth.isLoading
                          ? null
                          : () async {
                              if (!_formKey.currentState!.validate()) return;
                              await _goTables(
                                auth,
                                () => auth.login(
                                  email: _emailController.text.trim(),
                                  password: _passwordController.text.trim(),
                                  baseUrl: _urlController.text.trim(),
                                  restaurantNo:
                                      _restaurantNoController.text.trim(),
                                ),
                              );
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF97316),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 0,
                      ),
                      child: auth.isLoading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'ENTER DINE-IN TERMINAL',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),

                  if (kDebugMode) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: OutlinedButton(
                        onPressed: auth.isLoading
                            ? null
                            : () async {
                                await _goTables(
                                  auth,
                                  () => auth.enterDemoMode(
                                    baseUrl: _urlController.text.trim(),
                                  ),
                                );
                              },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF334155),
                          side: const BorderSide(color: Color(0xFFCBD5E1)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Skip login — UI demo only'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
