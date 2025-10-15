// lib/pages/login_page.dart
import 'package:church_management_app/pages/signup1.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _authService = AuthService();
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;

  late final FirebaseFunctions _functions;

  @override
  void initState() {
    super.initState();
    // Match your deployed region for Functions
    _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Subscribes this device to broadcast pings and syncs backend user doc & claims.
  Future<void> _postLoginBootstrap() async {
    // iOS: ask user; Android auto-grants if already allowed
    try {
      await FirebaseMessaging.instance.requestPermission();
    } catch (_) {
      // Non-fatal if permissions prompt fails (e.g., Android)
    }

    // Subscribe to global attendance topic so this device receives start pings
    try {
      await FirebaseMessaging.instance.subscribeToTopic('all_members');
    } catch (_) {
      // Not critical; attendance still works via future app sessions
    }

    // Ensure server-side user doc exists/updated (Admin SDK; bypasses rules)
    await _functions.httpsCallable('ensureUserDoc').call(<String, dynamic>{});

    // Sync single-role + custom claims from linked member record (non-fatal)
    try {
      await _functions.httpsCallable('syncUserRoleFromMemberOnLogin').call(<String, dynamic>{});
    } catch (_) {}
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    if (mounted) setState(() => _loading = true);

    try {
      final userCred = await _authService.signIn(
        _email.text.trim(),
        _password.text.trim(),
      );

      final user = userCred.user;
      if (user == null) {
        throw FirebaseAuthException(code: 'no-user', message: 'No user returned.');
      }

      // Ensure the callable gets a fresh ID token
      await user.getIdToken(true);

      // Post-login bootstrap: topic subscribe + ensureUserDoc + sync role/claims
      await _postLoginBootstrap();

      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/');
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Server error'), backgroundColor: Colors.red),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Login failed'), backgroundColor: Colors.red),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Login failed: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showForgotPasswordDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forgot Password'),
        content: const Text('Password reset is not implemented yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF6A11CB), Color(0xFF2575FC)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Container(
                padding: const EdgeInsets.all(20),
                margin: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    )
                  ],
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Icon(Icons.church, size: 80, color: Colors.deepPurple),
                      const SizedBox(height: 16),
                      const Text(
                        'Welcome to Resurrection Church',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Colors.deepPurple,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Join us in worship and community',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16, color: Colors.black87),
                      ),
                      const SizedBox(height: 30),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _email,
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.email),
                        ),
                        validator: (value) =>
                        value != null && value.contains('@') ? null : 'Enter a valid email',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                          prefixIcon: Icon(Icons.lock),
                        ),
                        obscureText: true,
                        validator: (value) =>
                        value != null && value.length >= 6 ? null : 'Min 6 characters',
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple),
                        onPressed: _loading ? null : _handleLogin,
                        child: _loading
                            ? const SizedBox(
                            width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text(
                          'Login',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: Colors.deepPurple),
                        onPressed: _showForgotPasswordDialog,
                        child: const Text('Forgot Password?'),
                      ),
                      const SizedBox(height: 10),
                      TextButton(
                        style: TextButton.styleFrom(foregroundColor: Colors.deepPurple),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const SignupStep1Page()),
                          );
                        },
                        child: const Text("Don't have an account? Sign Up"),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
