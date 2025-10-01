import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  final _formKey = GlobalKey<FormState>();

  String? _memberId;
  bool _loading = true;
  bool _saving = false;

  // Controllers
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _genderCtrl = TextEditingController(); // simple text; swap to dropdown if you prefer
  final _addressCtrl = TextEditingController();

  // Emergency contact
  final _emergencyNameCtrl = TextEditingController();
  final _emergencyPhoneCtrl = TextEditingController();

  // Marital status
  final List<String> _maritalOptions = const ['single', 'married', 'divorced', 'widowed'];
  String? _maritalStatus;

  // DOB
  DateTime? _dob;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _genderCtrl.dispose();
    _addressCtrl.dispose();
    _emergencyNameCtrl.dispose();
    _emergencyPhoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final user = _auth.currentUser;
    if (user == null) {
      setState(() {
        _loading = false;
      });
      return;
    }

    try {
      final u = await _db.collection('users').doc(user.uid).get();
      final udata = u.data() ?? {};
      final memberId = udata['memberId'] as String?;
      if (memberId == null) {
        if (mounted) {
          setState(() {
            _memberId = null;
            _loading = false;
          });
        }
        return;
      }

      final m = await _db.collection('members').doc(memberId).get();
      final md = m.data() ?? {};

      // Populate form fields
      _memberId = memberId;
      _firstNameCtrl.text = (md['firstName'] ?? '').toString();
      _lastNameCtrl.text = (md['lastName'] ?? '').toString();
      _emailCtrl.text = (md['email'] ?? udata['email'] ?? '').toString();
      _phoneCtrl.text = (md['phoneNumber'] ?? md['phone'] ?? '').toString();
      _genderCtrl.text = (md['gender'] ?? '').toString();
      _addressCtrl.text = (md['address'] ?? '').toString();
      _emergencyNameCtrl.text = (md['emergencyContactName'] ?? '').toString();
      _emergencyPhoneCtrl.text = (md['emergencyContactNumber'] ?? '').toString();
      final ms = (md['maritalStatus'] ?? '').toString().toLowerCase();
      _maritalStatus = _maritalOptions.contains(ms) ? ms : null;

      final ts = md['dateOfBirth'];
      if (ts is Timestamp) {
        _dob = ts.toDate();
      } else {
        _dob = null;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load profile: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
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
    if (picked != null) {
      setState(() {
        _dob = picked;
      });
    }
  }

  Future<void> _save() async {
    if (_memberId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No linked member record found.')),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final first = _firstNameCtrl.text.trim();
    final last = _lastNameCtrl.text.trim();
    final fullName = [first, last].where((s) => s.isNotEmpty).join(' ').trim();

    // Build an update map with ONLY allowed profile fields (per your rules)
    final Map<String, dynamic> update = {
      'firstName': first,
      'lastName': last,
      'fullName': fullName, // optional convenience
      'email': _emailCtrl.text.trim(),
      'phoneNumber': _phoneCtrl.text.trim(),
      'gender': _genderCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'emergencyContactName': _emergencyNameCtrl.text.trim(),
      'emergencyContactNumber': _emergencyPhoneCtrl.text.trim(),
      'maritalStatus': (_maritalStatus ?? '').trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (_dob != null) {
      update['dateOfBirth'] = Timestamp.fromDate(_dob!);
    } else {
      update['dateOfBirth'] = FieldValue.delete();
    }

    // Remove keys with empty string (avoid cluttering doc)
    update.removeWhere((k, v) => v is String && v.trim().isEmpty);

    setState(() => _saving = true);
    try {
      await _db.collection('members').doc(_memberId!).update(update);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Profile updated')),
        );
      }
    } on FirebaseException catch (e) {
      // Permission errors will show here if rules block a field
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Save failed: ${e.message ?? e.code}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Save failed: $e')),
        );
      }
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
          : _memberId == null
          ? _NoMemberLinked(onRefresh: _loadProfile)
          : SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _Header(percent: percent),
              const SizedBox(height: 16),

              // Name
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
                      validator: (v) {
                        // Allow last name only too; enforce at least one name later
                        return null;
                      },
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
                      validator: (v) => null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Email & Phone
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

              // Gender (simple text, keep consistent with your data)
              TextFormField(
                controller: _genderCtrl,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Gender',
                  prefixIcon: Icon(Icons.wc_outlined),
                  hintText: 'Male / Female / ...',
                ),
              ),
              const SizedBox(height: 12),

              // Marital status
              DropdownButtonFormField<String>(
                value: _maritalStatus,
                items: _maritalOptions
                    .map((v) => DropdownMenuItem(
                  value: v,
                  child: Text(v[0].toUpperCase() + v.substring(1)),
                ))
                    .toList(),
                decoration: const InputDecoration(
                  labelText: 'Marital status',
                  prefixIcon: Icon(Icons.favorite_outline),
                ),
                onChanged: (v) => setState(() => _maritalStatus = v),
              ),
              const SizedBox(height: 12),

              // Address
              TextFormField(
                controller: _addressCtrl,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Home address',
                  prefixIcon: Icon(Icons.home_outlined),
                ),
              ),
              const SizedBox(height: 12),

              // DOB (display + edit)
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
                            : DateFormat.yMMMMd().format(_dob!),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const Spacer(),
                      const Icon(Icons.edit_calendar_outlined),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Emergency contact
              TextFormField(
                controller: _emergencyNameCtrl,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Emergency contact name',
                  prefixIcon: Icon(Icons.contact_emergency_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emergencyPhoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Emergency contact number',
                  prefixIcon: Icon(Icons.local_phone_outlined),
                ),
              ),

              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _saving
                      ? null
                      : () {
                    // Require at least one name part
                    if (_firstNameCtrl.text.trim().isEmpty &&
                        _lastNameCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter at least a first or last name.')),
                      );
                      return;
                    }
                    _save();
                  },
                  icon: const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Saving...' : 'Save changes'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _computeCompletionPercent() {
    // a light approximation for progress
    int filled = 0;
    const total = 8; // adjust if you count differently

    if (_firstNameCtrl.text.trim().isNotEmpty || _lastNameCtrl.text.trim().isNotEmpty) filled++;
    if (_emailCtrl.text.trim().isNotEmpty) filled++;
    if (_phoneCtrl.text.trim().isNotEmpty) filled++;
    if (_genderCtrl.text.trim().isNotEmpty) filled++;
    if (_maritalStatus != null && _maritalStatus!.isNotEmpty) filled++;
    if (_addressCtrl.text.trim().isNotEmpty) filled++;
    if (_emergencyNameCtrl.text.trim().isNotEmpty || _emergencyPhoneCtrl.text.trim().isNotEmpty) filled++;
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
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, 6))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Profile completion', style: Theme.of(context).textTheme.titleMedium),
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
          Text('$pct% complete', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _NoMemberLinked extends StatelessWidget {
  final Future<void> Function() onRefresh;
  const _NoMemberLinked({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 60),
          Icon(Icons.link_off, size: 62, color: Colors.grey.shade600),
          const SizedBox(height: 16),
          const Text(
            'No member record linked',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            'Your account has no linked member profile yet. If you recently signed up, try pulling to refresh.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade700),
          ),
        ],
      ),
    );
  }
}
