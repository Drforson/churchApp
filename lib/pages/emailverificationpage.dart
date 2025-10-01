import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:church_management_app/pages/signup2.dart'; // ✅ Adjust import if needed

class EmailVerificationPage extends StatefulWidget {
  final String uid;
  final String email;

  const EmailVerificationPage({super.key, required this.uid, required this.email});

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  bool _sending = false;
  bool _checking = false;
  int _cooldown = 0;
  Timer? _cooldownTimer;
  Timer? _autoCheckTimer;

  @override
  void initState() {
    super.initState();
    _sendVerificationEmail();
    _startAutoCheckLoop();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _autoCheckTimer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    setState(() => _cooldown = 30); // 30 seconds
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_cooldown <= 1) {
        timer.cancel();
        if (mounted) setState(() => _cooldown = 0);
      } else {
        if (mounted) setState(() => _cooldown--);
      }
    });
  }

  void _startAutoCheckLoop() {
    _autoCheckTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await user.reload();
        if (!mounted) return;

        final refreshedUser = FirebaseAuth.instance.currentUser;
        if (refreshedUser != null && refreshedUser.emailVerified) {
          timer.cancel();
          if (!mounted) return;

          _navigateToNextStep(); // ✅ auto-route
        }
      }
    });
  }

  Future<void> _sendVerificationEmail() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && !user.emailVerified) {
      try {
        setState(() => _sending = true);
        await user.sendEmailVerification();
        _startCooldown();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Verification email sent!')),
        );
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send email: $e')),
        );
      } finally {
        if (mounted) setState(() => _sending = false);
      }
    }
  }

  Future<void> _checkEmailVerified() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _checking = true);

    try {
      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;

      if (!mounted) return;

      if (refreshedUser != null && refreshedUser.emailVerified) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Email verified!')),
        );
        _navigateToNextStep();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Email not verified yet.')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error checking verification: $e')),
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _navigateToNextStep() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => SignupStep2Page(
          uid: widget.uid,
          email: widget.email.trim().toLowerCase(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify Your Email')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Please verify your email address.\nCheck your inbox and click the verification link.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: (_cooldown > 0 || _sending) ? null : _sendVerificationEmail,
                icon: _sending
                    ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
                    : const Icon(Icons.email),
                label: Text(_cooldown > 0
                    ? 'Resend Email ($_cooldown s)'
                    : 'Resend Verification Email'),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _checking ? null : _checkEmailVerified,
                icon: _checking
                    ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
                    : const Icon(Icons.check),
                label: const Text('Check Verification'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
