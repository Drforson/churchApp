import 'package:church_management_app/pages/emailverificationpage.dart';
import 'package:church_management_app/services/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class SignupStep1Page extends StatefulWidget {
  const SignupStep1Page({super.key});

  @override
  State<SignupStep1Page> createState() => _SignupStep1PageState();
}

class _SignupStep1PageState extends State<SignupStep1Page> {
  final _formKey = GlobalKey<FormState>();
  final _authService = AuthService.instance;
  final FirebaseAuth _firebaseAuth = FirebaseAuth.instance;

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _emailExists = false;
  bool _obscure = true;
  String _lastCheckedEmail = '';

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _isFormValid {
    return _formKey.currentState?.validate() == true && !_emailExists;
  }

  Future<void> _checkEmailExists(String email) async {
    final v = email.trim().toLowerCase();

    // Avoid repeat calls for the same value
    if (v.isEmpty || v == _lastCheckedEmail) return;

    _lastCheckedEmail = v;

    try {
      final methods = await _firebaseAuth.fetchSignInMethodsForEmail(v);
      if (!mounted) return;
      setState(() {
        _emailExists = methods.isNotEmpty;
      });
    } catch (e) {
      // Non-fatal: do not block signup on this
      if (!mounted) return;
      setState(() => _emailExists = false);
    }
  }

  Future<void> _handleSignup() async {
    // Trigger validators
    if (!_isFormValid) return;

    setState(() => _loading = true);

    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      final userCred = await _authService.signUp(email, password);
      final user = userCred.user;
      if (user == null) {
        throw FirebaseAuthException(
          code: 'unknown',
          message: 'Signup failed. No user returned.',
        );
      }

      // Send Email Verification (AuthService only handles doc/roles/claims)
      if (!user.emailVerified) {
        await user.sendEmailVerification();
      }
      await user.reload();

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => EmailVerificationPage(
            uid: user.uid,
            email: user.email ?? email,
          ),
        ),
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyAuthError(e)),
          backgroundColor: Colors.red,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendlyAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':
        return 'That email is already registered.';
      case 'invalid-email':
        return 'Please enter a valid email.';
      case 'weak-password':
        return 'Please choose a stronger password (min 6 characters).';
      default:
        return e.message ?? 'Authentication error.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          onChanged: () => setState(() {}), // live-enable button
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              const Text(
                'Step 1: Account Setup',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),

              // Email
              TextFormField(
                controller: _emailController,
                decoration: InputDecoration(
                  labelText: 'Email Address',
                  prefixIcon: const Icon(Icons.email),
                  suffixIcon: _emailController.text.isEmpty
                      ? null
                      : (_emailExists
                      ? const Icon(Icons.warning, color: Colors.red)
                      : const Icon(Icons.check_circle, color: Colors.green)),
                ),
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                onChanged: (value) {
                  final v = value.trim();
                  // Only check once it looks like an email
                  if (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) {
                    _checkEmailExists(v);
                  } else {
                    setState(() => _emailExists = false);
                  }
                },
                validator: (val) {
                  final v = (val ?? '').trim();
                  if (v.isEmpty) return 'Email is required';
                  final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v);
                  if (!ok) return 'Enter a valid email';
                  if (_emailExists) return 'Email already registered';
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // Password
              TextFormField(
                controller: _passwordController,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (val) {
                  if (val == null || val.isEmpty) {
                    return 'Password is required';
                  }
                  if (val.length < 6) {
                    return 'Password must be at least 6 characters';
                  }
                  return null;
                },
              ),

              const SizedBox(height: 40),

              // Continue
              ElevatedButton(
                onPressed: _isFormValid && !_loading ? _handleSignup : null,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: Colors.indigo,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _loading
                    ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
                    : const Text(
                  'Continue',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
