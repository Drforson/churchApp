import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:church_management_app/pages/membership_form_page.dart';

class EmailVerificationPage extends StatefulWidget {
  final String uid;
  final String email;

  const EmailVerificationPage({
    super.key,
    required this.uid,
    required this.email,
  });

  @override
  State<EmailVerificationPage> createState() => _EmailVerificationPageState();
}

class _EmailVerificationPageState extends State<EmailVerificationPage> {
  bool _sending = false;
  bool _checking = false;
  int _cooldown = 0;

  Timer? _cooldownTimer;
  Timer? _autoCheckTimer;
  bool _navigated = false;

  FirebaseAuth get _auth => FirebaseAuth.instance;

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
    _cooldownTimer?.cancel();
    _cooldownTimer =
        Timer.periodic(const Duration(seconds: 1), (Timer timer) {
          if (!mounted) {
            timer.cancel();
            return;
          }

          if (_cooldown <= 1) {
            timer.cancel();
            setState(() => _cooldown = 0);
          } else {
            setState(() => _cooldown--);
          }
        });
  }

  void _startAutoCheckLoop() {
    _autoCheckTimer?.cancel();
    _autoCheckTimer =
        Timer.periodic(const Duration(seconds: 5), (Timer timer) async {
          if (!mounted || _navigated) {
            timer.cancel();
            return;
          }

          final user = _auth.currentUser;
          if (user == null || user.uid != widget.uid) {
            // User changed or signed out — bail out
            timer.cancel();
            if (!mounted) return;
            Navigator.of(context).pop();
            return;
          }

          await user.reload();
          if (!mounted || _navigated) return;

          final refreshedUser = _auth.currentUser;
          if (refreshedUser != null && refreshedUser.emailVerified) {
            timer.cancel();
            _navigateToNextStep();
          }
        });
  }

  Future<void> _sendVerificationEmail() async {
    final user = _auth.currentUser;
    if (user == null || user.uid != widget.uid) return;

    if (user.emailVerified) {
      // Already verified → go next
      _navigateToNextStep();
      return;
    }

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

  Future<void> _checkEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null || user.uid != widget.uid) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You are not signed in. Please log in again.'),
        ),
      );
      return;
    }

    setState(() => _checking = true);

    try {
      await user.reload();
      final refreshedUser = _auth.currentUser;

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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error checking verification: $e')),
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _navigateToNextStep() {
    if (!mounted || _navigated) return;
    _navigated = true;

    _autoCheckTimer?.cancel();
    _cooldownTimer?.cancel();

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => MembershipFormPage(
          selfSignup: true,
          prefillEmail: widget.email.trim().toLowerCase(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final emailDisplay = widget.email.trim();

    return Scaffold(
      appBar: AppBar(title: const Text('Verify Your Email')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'We’ve sent a verification link to:\n$emailDisplay\n\n'
                    'Please check your inbox and tap the link to continue.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed:
                (_cooldown > 0 || _sending) ? null : _sendVerificationEmail,
                icon: _sending
                    ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
                    : const Icon(Icons.email),
                label: Text(
                  _cooldown > 0
                      ? 'Resend Email ($_cooldown s)'
                      : 'Resend Verification Email',
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _checking ? null : _checkEmailVerified,
                icon: _checking
                    ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
                    : const Icon(Icons.check),
                label: const Text('I\'ve Verified – Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
