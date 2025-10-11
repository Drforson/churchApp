import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Collection name used by Cloud Function onCreate trigger to notify pastors.
const String _kPrayerRequestsCol = 'prayerRequests';

class PrayerRequestFormPage extends StatefulWidget {
  const PrayerRequestFormPage({super.key});

  @override
  State<PrayerRequestFormPage> createState() => _PrayerRequestFormPageState();
}

class _PrayerRequestFormPageState extends State<PrayerRequestFormPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();

  bool _isAnonymous = false;
  bool _submitting = false;

  String? _uid;
  String? _linkedMemberId;

  @override
  void initState() {
    super.initState();
    _preloadUserBits();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _preloadUserBits() async {
    final user = _auth.currentUser;
    if (user == null) return;
    setState(() {
      _uid = user.uid;
      _emailCtrl.text = user.email ?? _emailCtrl.text;
    });

    try {
      // Try to pull memberId and full name to prefill.
      final userSnap = await _db.collection('users').doc(user.uid).get();
      final u = userSnap.data() ?? {};
      final memberId = (u['memberId'] ?? '').toString();
      if (memberId.isNotEmpty) {
        setState(() => _linkedMemberId = memberId);
        final mem = await _db.collection('members').doc(memberId).get();
        if (mem.exists) {
          final m = mem.data() as Map<String, dynamic>;
          final full = (m['fullName'] ?? '').toString().trim();
          final fn = (m['firstName'] ?? '').toString().trim();
          final ln = (m['lastName'] ?? '').toString().trim();
          final composed = full.isNotEmpty ? full : [fn, ln].where((s) => s.isNotEmpty).join(' ').trim();
          if (composed.isNotEmpty && mounted && _nameCtrl.text.trim().isEmpty) {
            _nameCtrl.text = composed;
          }
          if ((m['email'] ?? '').toString().isNotEmpty && mounted && _emailCtrl.text.trim().isEmpty) {
            _emailCtrl.text = (m['email'] ?? '').toString();
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _ensureSignedIn() async {
    // Allow everyone to submit: if not signed in, sign in anonymously.
    if (_auth.currentUser != null) return;
    final cred = await _auth.signInAnonymously();
    setState(() => _uid = cred.user?.uid);
  }

  Future<void> _submit() async {
    if (_submitting) return;

    if (!_isAnonymous) {
      if (!_formKey.currentState!.validate()) return;
    } else {
      // For anonymous requests we still require a message.
      if (_messageCtrl.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter your prayer request.')),
        );
        return;
      }
    }

    setState(() => _submitting = true);
    try {
      await _ensureSignedIn();

      final now = FieldValue.serverTimestamp();
      final map = <String, dynamic>{
        'message': _messageCtrl.text.trim(),
        'isAnonymous': _isAnonymous,
        'requestedAt': now,
        'updatedAt': now,
        'status': 'new', // new | prayed | archived (managed by pastors/admins)
      };

      // Attach identity hints if not anonymous
      if (!_isAnonymous) {
        final name = _nameCtrl.text.trim();
        final email = _emailCtrl.text.trim();
        if (name.isNotEmpty) map['name'] = name;
        if (email.isNotEmpty) map['email'] = email;
      }

      // Link requester where possible (helps name resolution + role gating server-side)
      if (_uid != null && _uid!.isNotEmpty) {
        map['requestedByUid'] = _uid;
      }
      if (_linkedMemberId != null && _linkedMemberId!.isNotEmpty) {
        map['requesterMemberId'] = _linkedMemberId;
      }

      await _db.collection(_kPrayerRequestsCol).add(map);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Prayer request submitted')),
      );
      _formKey.currentState?.reset();
      _messageCtrl.clear();
      if (_isAnonymous) {
        _nameCtrl.clear();
        _emailCtrl.clear();
      }
      setState(() {
        _isAnonymous = false;
      });
    } on FirebaseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Failed to submit: ${e.message ?? e.code}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Failed to submit: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canEditIdentity = !_isAnonymous;

    return Scaffold(
      appBar: AppBar(title: const Text('Prayer Request')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AutofillGroup(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    value: _isAnonymous,
                    onChanged: (v) => setState(() => _isAnonymous = v),
                    title: const Text('Submit anonymously'),
                    subtitle: const Text("If enabled, your name and email won't be shown to pastors."),
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _nameCtrl,
                    enabled: canEditIdentity,
                    decoration: const InputDecoration(
                      labelText: 'Name (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _emailCtrl,
                    enabled: canEditIdentity,
                    decoration: const InputDecoration(
                      labelText: 'Email (optional)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                    validator: (v) {
                      if (!canEditIdentity) return null;
                      final s = (v ?? '').trim();
                      if (s.isEmpty) return null;
                      final ok = RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(s);
                      return ok ? null : 'Enter a valid email';
                    },
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _messageCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Your prayer request',
                      border: OutlineInputBorder(),
                    ),
                    minLines: 5,
                    maxLines: 10,
                    validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Please enter your prayer request' : null,
                  ),
                  const SizedBox(height: 16),

                  FilledButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    label: const Text('Submit'),
                  ),

                  const SizedBox(height: 12),
                  const Text(
                    'Pastors receive a notification when you submit.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
