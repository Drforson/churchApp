import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:church_management_app/services/auth_service.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  late final FirebaseFunctions _functions; // europe-west2 functions
  final AuthService _authService = AuthService.instance;

  final _formKey = GlobalKey<FormState>();

  String? _memberId;
  bool _loading = true;
  bool _saving = false;

  bool _bypassMode = false;
  int _cooldownSecs = 0;
  Timer? _cooldownTimer;

  // Controllers
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _emergencyNameCtrl = TextEditingController();
  final _emergencyPhoneCtrl = TextEditingController();

  final List<String> _maritalOptions = const ['single', 'married', 'divorced', 'widowed'];
  String? _maritalStatus;

  final List<String> _genderOptions = const ['male', 'female', 'other'];
  String? _genderStatus;

  DateTime? _dob;

  @override
  void initState() {
    super.initState();
    _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');
    _loadProfile();
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _emergencyNameCtrl.dispose();
    _emergencyPhoneCtrl.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = _auth.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      final emailLc = (user.email ?? '').trim().toLowerCase();
      final now = FieldValue.serverTimestamp();

      // Ensure users/{uid} exists (idempotent, allowed by rules)
      final userRef = _db.collection('users').doc(user.uid);
      final userSnap = await userRef.get();

      if (!userSnap.exists) {
        await userRef.set(
          {
            'email': emailLc,
            'createdAt': now,
            'updatedAt': now,
          },
          SetOptions(merge: true),
        );
      } else {
        await userRef.set(
          {
            if (emailLc.isNotEmpty) 'email': emailLc,
            'updatedAt': now,
          },
          SetOptions(merge: true),
        );
      }

      if (_emailCtrl.text.trim().isEmpty && user.email != null) {
        _emailCtrl.text = user.email!;
      }

      // Check link
      final uSnap = await userRef.get();
      String? memberId = (uSnap.data()?['memberId'] as String?)?.trim();

      // Try auto-link by email if not linked
      if ((memberId == null || memberId.isEmpty) && emailLc.isNotEmpty) {
        final existing = await _db
            .collection('members')
            .where('email', isEqualTo: emailLc)
            .limit(1)
            .get();
        if (existing.docs.isNotEmpty) {
          final foundId = existing.docs.first.id;
          await userRef.set(
            {
              'memberId': foundId,
              'linkedAt': now,
              'updatedAt': now,
            },
            SetOptions(merge: true),
          );
          memberId = foundId;

          // Keep role & claims in sync immediately (linking can change role)
          try {
            await _functions
                .httpsCallable('syncUserRoleFromMemberOnLogin')
                .call();
            await user.getIdToken(true);
          } catch (e) {
            debugPrint('syncUserRoleFromMemberOnLogin (auto-link) failed: $e');
          }
        }
      }

      if (memberId == null || memberId.isEmpty) {
        setState(() {
          _memberId = null;
          _loading = false;
        });
        return;
      }

      final mSnap = await _db.collection('members').doc(memberId).get();
      final md = mSnap.data() ?? {};

      _memberId = memberId;
      _firstNameCtrl.text = (md['firstName'] ?? '').toString();
      _lastNameCtrl.text = (md['lastName'] ?? '').toString();
      _emailCtrl.text = (md['email'] ?? user.email ?? '').toString();
      _phoneCtrl.text = (md['phoneNumber'] ?? md['phone'] ?? '').toString();
      _addressCtrl.text = (md['address'] ?? '').toString();
      _emergencyNameCtrl.text = (md['emergencyContactName'] ?? '').toString();
      _emergencyPhoneCtrl.text = (md['emergencyContactNumber'] ?? '').toString();

      final g = (md['gender'] ?? '').toString().toLowerCase().trim();
      _genderStatus = _genderOptions.contains(g) ? g : null;

      final ms = (md['maritalStatus'] ?? '').toString().toLowerCase().trim();
      _maritalStatus = _maritalOptions.contains(ms) ? ms : null;

      final ts = md['dateOfBirth'];
      _dob = ts is Timestamp ? ts.toDate() : null;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load profile: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDOB() async {
    final now = DateTime.now();
    final initial = _dob ?? DateTime(now.year - 18, now.month, now.day);
    final first = DateTime(now.year - 110, 1, 1);
    final last = DateTime(now.year, now.month, now.day);

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: 'Select Date of Birth',
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _resendVerificationEmail() async {
    final user = _auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not signed in.')),
      );
      return;
    }
    if (_cooldownSecs > 0) return;

    try {
      await user.reload();
      if (_auth.currentUser?.emailVerified == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Email already verified. Pull to refresh.')),
        );
        return;
      }
      await user.sendEmailVerification();
      _startCooldown(60);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
          Text('Verification email sent to ${user.email ?? 'your email'}'),
        ),
      );
    } on FirebaseAuthException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
          Text('Could not send verification: ${e.message ?? e.code}'),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send verification: $e')),
      );
    }
  }

  void _startCooldown(int seconds) {
    _cooldownTimer?.cancel();
    setState(() => _cooldownSecs = seconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_cooldownSecs <= 1) {
        t.cancel();
        setState(() => _cooldownSecs = 0);
      } else {
        setState(() => _cooldownSecs -= 1);
      }
    });
  }

  void _enableBypassAndShowForm() {
    final user = _auth.currentUser;
    setState(() {
      _bypassMode = true;
      if (user?.email != null && _emailCtrl.text.trim().isEmpty) {
        _emailCtrl.text = user!.email!;
      }
    });
  }

  Future<void> _save() async {
    // Require at least one name
    if (_firstNameCtrl.text.trim().isEmpty &&
        _lastNameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter at least a first or last name.'),
        ),
      );
      return;
    }

    final user = _auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not signed in.')),
      );
      return;
    }

    final first = _firstNameCtrl.text.trim();
    final last = _lastNameCtrl.text.trim();
    final fullName =
    [first, last].where((s) => s.isNotEmpty).join(' ').trim();
    final emailLc = _emailCtrl.text.trim().toLowerCase();

    final Map<String, dynamic> profilePayload = {
      'firstName': first,
      'lastName': last,
      'fullName': fullName,
      'email': emailLc,
      'phoneNumber': _phoneCtrl.text.trim(),
      'gender': (_genderStatus ?? '').trim(),
      'address': _addressCtrl.text.trim(),
      'emergencyContactName': _emergencyNameCtrl.text.trim(),
      'emergencyContactNumber': _emergencyPhoneCtrl.text.trim(),
      'maritalStatus': (_maritalStatus ?? '').trim(),
      'updatedAt': FieldValue.serverTimestamp(),
      if (_dob != null) 'dateOfBirth': Timestamp.fromDate(_dob!),
      if (_dob == null) 'dateOfBirth': FieldValue.delete(),
    };

    // Don’t send empty strings to Firestore
    profilePayload.removeWhere((k, v) => v is String && v.trim().isEmpty);

    setState(() => _saving = true);
    try {
      if (_memberId == null) {
        // ---------- CREATE via AuthService (enforces email verification) ----------
        final emailForMember = (emailLc.isNotEmpty
            ? emailLc
            : (user.email ?? ''))
            .toLowerCase();

        await _authService.completeMemberProfile(
          uid: user.uid,
          email: emailForMember,
          firstName: first,
          lastName: last,
          phoneNumber: _phoneCtrl.text.trim(),
          gender: (_genderStatus ?? '').trim(),
          dateOfBirth: _dob ?? DateTime(1900, 1, 1),
        );

        // Fetch the linked memberId for local state
        final uSnap = await _db.collection('users').doc(user.uid).get();
        _memberId = uSnap.data()?['memberId'] as String?;

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ Profile created & linked')),
          );
        }
      } else {
        // ---------- UPDATE (client-side; allowed by rules) ----------
        await _db.collection('members').doc(_memberId!).update(profilePayload);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✅ Profile updated')),
          );
        }
      }
    } on FirebaseFunctionsException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
          Text('❌ Cloud Function error: ${e.code} – ${e.message}'),
        ),
      );
    } on FirebaseAuthException catch (e) {
      // This commonly catches the "email-not-verified" case from completeMemberProfile
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ ${e.message ?? e.code}')),
      );
    } on FirebaseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Save failed: ${e.message ?? e.code}'),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Save failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final percent = _computeCompletionPercent();

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Profile'),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_memberId == null && !_bypassMode)
          ? _NoMemberSection(
        onRefresh: _loadProfile,
        onResend: _resendVerificationEmail,
        onBypass: _enableBypassAndShowForm,
        email: _auth.currentUser?.email,
        cooldownSecs: _cooldownSecs,
      )
          : SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding:
            const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _Header(percent: percent),
              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _firstNameCtrl,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'First name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lastNameCtrl,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Last name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Email (optional)',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Phone number',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: 12),

              DropdownButtonFormField<String>(
                value: _genderStatus,
                items: _genderOptions
                    .map(
                      (v) => DropdownMenuItem(
                    value: v,
                    child: Text(
                        v[0].toUpperCase() +
                            v.substring(1)),
                  ),
                )
                    .toList(),
                decoration: const InputDecoration(
                  labelText: 'Select Gender',
                  prefixIcon: Icon(Icons.wc_outlined),
                ),
                onChanged: (v) =>
                    setState(() => _genderStatus = v),
              ),
              const SizedBox(height: 12),

              DropdownButtonFormField<String>(
                value: _maritalStatus,
                items: _maritalOptions
                    .map(
                      (v) => DropdownMenuItem(
                    value: v,
                    child: Text(
                        v[0].toUpperCase() +
                            v.substring(1)),
                  ),
                )
                    .toList(),
                decoration: const InputDecoration(
                  labelText: 'Marital status',
                  prefixIcon: Icon(Icons.favorite_outline),
                ),
                onChanged: (v) =>
                    setState(() => _maritalStatus = v),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _addressCtrl,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Home address',
                  prefixIcon: Icon(Icons.home_outlined),
                ),
              ),
              const SizedBox(height: 12),

              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _pickDOB,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date of birth',
                    prefixIcon: Icon(Icons.cake_outlined),
                    border: OutlineInputBorder(),
                  ),
                  child: Row(
                    children: [
                      Text(
                        _dob == null
                            ? 'Tap to select'
                            : DateFormat.yMMMMd()
                            .format(_dob!),
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium,
                      ),
                      const Spacer(),
                      const Icon(
                          Icons.edit_calendar_outlined),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              TextFormField(
                controller: _emergencyNameCtrl,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Emergency contact name',
                  prefixIcon:
                  Icon(Icons.contact_emergency_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emergencyPhoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Emergency contact number',
                  prefixIcon:
                  Icon(Icons.local_phone_outlined),
                ),
              ),

              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: Text(
                    _saving
                        ? 'Saving...'
                        : (_memberId == null
                        ? 'Create profile'
                        : 'Save changes'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _computeCompletionPercent() {
    int filled = 0;
    const total = 8;
    if (_firstNameCtrl.text.trim().isNotEmpty ||
        _lastNameCtrl.text.trim().isNotEmpty) filled++;
    if (_emailCtrl.text.trim().isNotEmpty) filled++;
    if (_phoneCtrl.text.trim().isNotEmpty) filled++;
    if (_genderStatus != null && _genderStatus!.isNotEmpty) filled++;
    if (_maritalStatus != null && _maritalStatus!.isNotEmpty) filled++;
    if (_addressCtrl.text.trim().isNotEmpty) filled++;
    if (_emergencyNameCtrl.text.trim().isNotEmpty ||
        _emergencyPhoneCtrl.text.trim().isNotEmpty) filled++;
    if (_dob != null) filled++;
    return (filled / total).clamp(0.0, 1.0);
  }
}

/* ---------- small helper widgets ---------- */

class _Header extends StatelessWidget {
  final double percent;
  const _Header({required this.percent});

  @override
  Widget build(BuildContext context) {
    final pct = (percent * 100).toInt();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Profile completion',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: percent,
              minHeight: 10,
              backgroundColor: Colors.grey.shade200,
              color: const Color(0xFF10B981),
            ),
          ),
          const SizedBox(height: 6),
          Text('$pct% complete',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _NoMemberSection extends StatelessWidget {
  final Future<void> Function() onRefresh;
  final VoidCallback onResend;
  final VoidCallback onBypass;
  final String? email;
  final int cooldownSecs;

  const _NoMemberSection({
    required this.onRefresh,
    required this.onResend,
    required this.onBypass,
    required this.email,
    required this.cooldownSecs,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 40),
          Icon(Icons.person_search_outlined,
              size: 62, color: Colors.grey.shade700),
          const SizedBox(height: 16),
          const Text(
            'No member profile linked',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'If you just signed up, you might need to verify your email and refresh.\n'
                'Account email: ${email ?? 'unknown'}',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: cooldownSecs > 0 ? null : onResend,
              icon: const Icon(Icons.mark_email_unread_outlined),
              label: Text(
                cooldownSecs > 0
                    ? 'Resend verification (${cooldownSecs}s)'
                    : 'Resend verification email',
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onBypass,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Bypass & create profile now'),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Bypass lets you fill out your profile now. We’ll create a member record and link it to your account (email must still be verified).',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}
