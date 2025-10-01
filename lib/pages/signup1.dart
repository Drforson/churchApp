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
  final _authService = AuthService();

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _emailExists = false;

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
    try {
      final methods = await FirebaseAuth.instance.fetchSignInMethodsForEmail(email);
      setState(() {
        _emailExists = methods.isNotEmpty;
      });
    } catch (e) {
      setState(() {
        _emailExists = false;
      });
    }
  }

  Future<void> _handleSignup() async {
    if (!_isFormValid) return;

    setState(() => _loading = true);

    try {
      final userCred = await _authService.signUp(
        _emailController.text.trim(),
        _passwordController.text.trim(),
      );

      final user = userCred.user;
      if (user == null) {
        throw Exception('Signup failed. No user returned.');
      }

      // Associate user with member if already exists
      await _authService.associateMemberWithUser(user.uid, _emailController.text.trim());

      // 🔥 Send Email Verification
      if (!user.emailVerified) {
        await user.sendEmailVerification();
      }

      await user.reload();

      // ✅ Go to Email Verification Page
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => EmailVerificationPage(
            uid: user.uid,
            email: user.email!,
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _loading = false);
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
          onChanged: () => setState(() {}),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              const Text(
                "Step 1: Account Setup",
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              TextFormField(
                controller: _emailController,
                decoration: InputDecoration(
                  labelText: 'Email Address',
                  prefixIcon: const Icon(Icons.email),
                  suffixIcon: _emailExists
                      ? const Icon(Icons.warning, color: Colors.red)
                      : const Icon(Icons.check_circle, color: Colors.green),
                ),
                keyboardType: TextInputType.emailAddress,
                onChanged: (value) {
                  if (value.contains('@')) {
                    _checkEmailExists(value.trim());
                  }
                },
                validator: (val) {
                  if (val == null || val.isEmpty) {
                    return 'Email is required';
                  }
                  if (!val.contains('@')) {
                    return 'Enter a valid email';
                  }
                  if (_emailExists) {
                    return 'Email already registered';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(Icons.lock),
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
              ElevatedButton(
                onPressed: _isFormValid && !_loading ? _handleSignup : null,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: Colors.indigo,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _loading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Continue', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
