import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:church_management_app/services/auth_service.dart';

class MembershipFormPage extends StatefulWidget {
  final bool selfSignup;
  final String? prefillEmail;

  const MembershipFormPage({
    super.key,
    this.selfSignup = false,
    this.prefillEmail,
  });

  @override
  State<MembershipFormPage> createState() => _MembershipFormPageState();
}

class _MembershipFormPageState extends State<MembershipFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _ecNameCtrl = TextEditingController();
  final _ecRelationCtrl = TextEditingController();
  final _ecPhoneCtrl = TextEditingController();
  final _preferredContactCtrl = TextEditingController();

  DateTime? _dob;
  String? _gender;
  bool _consent = false;
  bool _isVisitor = false;

  List<String> _selectedMinistries = [];
  List<String> _availableMinistries = [];
  bool _loadingMinistries = true;
  final FirebaseFunctions _functions =
      FirebaseFunctions.instanceFor(region: 'europe-west2');

  @override
  void initState() {
    super.initState();
    if (widget.selfSignup) {
      final authEmail = FirebaseAuth.instance.currentUser?.email;
      final prefill = widget.prefillEmail ?? authEmail ?? '';
      _emailCtrl.text = prefill.trim().toLowerCase();
      _selectedMinistries = ['ordinary member'];
    }
    _fetchMinistries();
  }

  Future<void> _fetchMinistries() async {
    final snapshot = await FirebaseFirestore.instance.collection('ministries').get();
    setState(() {
      _availableMinistries = snapshot.docs.map((doc) => doc['name'].toString()).toList();
      _loadingMinistries = false;
    });
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _ecNameCtrl.dispose();
    _ecRelationCtrl.dispose();
    _ecPhoneCtrl.dispose();
    _preferredContactCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.subtract(const Duration(days: 365 * 20)),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => _dob = picked);
    }
  }

  Future<void> _submit() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to register a member.')),
      );
      return;
    }

    if (!_formKey.currentState!.validate() || _dob == null || _gender == null || !_consent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill all required fields and give consent.')),
      );
      return;
    }

    if (!_isVisitor && _selectedMinistries.isEmpty) {
      if (widget.selfSignup) {
        _selectedMinistries = ['member'];
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select at least one ministry.')),
        );
        return;
      }
    }

    final first = _firstNameCtrl.text.trim();
    final last = _lastNameCtrl.text.trim();
    final fullName = [first, last].where((s) => s.isNotEmpty).join(' ').trim();
    final emailLc = _emailCtrl.text.trim().toLowerCase();
    final genderLc = _gender?.toLowerCase().trim();

    if (widget.selfSignup) {
      if (!currentUser.emailVerified) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please verify your email first.')),
        );
        return;
      }

      final authEmail = (currentUser.email ?? emailLc).trim().toLowerCase();

      await AuthService.instance.completeMemberProfile(
        uid: currentUser.uid,
        email: authEmail,
        firstName: first,
        lastName: last,
        phoneNumber: _phoneCtrl.text.trim(),
        gender: genderLc ?? '',
        dateOfBirth: _dob!,
      );

      await AuthService.instance.refreshServerRoleAndClaims();

      String? memberId;
      final userSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .get();
      memberId = userSnap.data()?['memberId'] as String?;

      if (memberId == null || memberId.isEmpty) {
        // Try to find a member by userUid or email
        final byUid = await FirebaseFirestore.instance
            .collection('members')
            .where('userUid', isEqualTo: currentUser.uid)
            .limit(1)
            .get();
        if (byUid.docs.isNotEmpty) {
          memberId = byUid.docs.first.id;
        } else {
          final byEmail = await FirebaseFirestore.instance
              .collection('members')
              .where('email', isEqualTo: authEmail)
              .orderBy('updatedAt', descending: true)
              .limit(1)
              .get();
          if (byEmail.docs.isNotEmpty) {
            memberId = byEmail.docs.first.id;
          }
        }
      }

      if (memberId == null || memberId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile saved, but link is still syncing. Please try again shortly.')),
        );
        return;
      }

      // Ensure users.memberId is set on the server
      try {
        await _functions.httpsCallable('linkSelfAfterVerification').call();
        await currentUser.getIdToken(true);
      } catch (_) {}

      if (memberId == null || memberId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile created, but link is still syncing. Please refresh.')),
        );
        return;
      }

      await FirebaseFirestore.instance.collection('members').doc(memberId).update({
        'email': authEmail,
        'address': _addressCtrl.text.trim(),
        'preferredContactMethod': _preferredContactCtrl.text.trim(),
        'ministries': _selectedMinistries,
        'emergencyContactName': _ecNameCtrl.text.trim(),
        'emergencyContactRelationship': _ecRelationCtrl.text.trim(),
        'emergencyContactNumber': _ecPhoneCtrl.text.trim(),
        'consentToDataUse': _consent,
        'isVisitor': _isVisitor,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, '/role-gate', (_) => false);
    } else {
      await FirebaseFirestore.instance.collection('members').add({
        'firstName': first,
        'lastName': last,
        'fullName': fullName,
        'fullNameLower': fullName.toLowerCase(),
        'phoneNumber': _phoneCtrl.text.trim(),
        'email': emailLc,
        'address': _addressCtrl.text.trim(),
        'preferredContactMethod': _preferredContactCtrl.text.trim(),
        'ministries': _selectedMinistries,
        'emergencyContactName': _ecNameCtrl.text.trim(),
        'emergencyContactRelationship': _ecRelationCtrl.text.trim(),
        'emergencyContactNumber': _ecPhoneCtrl.text.trim(),
        'dateOfBirth': Timestamp.fromDate(_dob!),
        'gender': genderLc,
        'consentToDataUse': _consent,
        'isVisitor': _isVisitor,
        'createdByUid': currentUser.uid,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }

    if (!widget.selfSignup) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Member registered!'),
        ),
      );
      _formKey.currentState!.reset();
      setState(() {
        _dob = null;
        _gender = null;
        _consent = false;
        _isVisitor = false;
        _selectedMinistries = [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tfStyle = Theme.of(context).textTheme.bodyLarge;
    return Scaffold(
      appBar: AppBar(title: const Text('New Membership')),
      body: Container(
        color: const Color(0xFFF3F6FA),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: SingleChildScrollView(
          child: Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _firstNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'First Name *',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _lastNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Last Name *',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      textInputAction: TextInputAction.next,
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: _pickDob,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Date of Birth *',
                          prefixIcon: Icon(Icons.cake_outlined),
                        ),
                        child: Text(
                          _dob == null ? 'Tap to select' : DateFormat.yMMMd().format(_dob!),
                          style: tfStyle,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      decoration: const InputDecoration(
                        labelText: 'Gender *',
                        prefixIcon: Icon(Icons.wc_outlined),
                      ),
                      items: ['Male', 'Female', 'Other'].map((g) => DropdownMenuItem(value: g, child: Text(g))).toList(),
                      value: _gender,
                      validator: (v) => v == null ? 'Required' : null,
                      onChanged: (v) => setState(() => _gender = v),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _phoneCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Phone *',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _emailCtrl,
                      enabled: !widget.selfSignup,
                      decoration: const InputDecoration(
                        labelText: 'Email *',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        final pattern = RegExp(r'^[^@]+@[^@]+\.[^@]+');
                        return !pattern.hasMatch(v.trim()) ? 'Invalid email' : null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _addressCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Home Address',
                        prefixIcon: Icon(Icons.home_outlined),
                      ),
                      maxLines: 2,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _preferredContactCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Preferred Contact Method',
                        prefixIcon: Icon(Icons.forum_outlined),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      title: const Text('Visitor'),
                      subtitle: const Text('Mark as visitor (no ministry selection required)'),
                      value: _isVisitor,
                      onChanged: (val) {
                        setState(() {
                          _isVisitor = val;
                          if (_isVisitor) {
                            _selectedMinistries.clear();
                          }
                        });
                      },
                      secondary: const Icon(Icons.person_outline),
                    ),
                    const SizedBox(height: 12),
                    _isVisitor
                        ? const SizedBox.shrink()
                        : _loadingMinistries
                        ? const Center(child: CircularProgressIndicator())
                        : InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Select Ministries *',
                        prefixIcon: Icon(Icons.groups_outlined),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _availableMinistries.map((ministry) {
                          final scheme = Theme.of(context).colorScheme;
                          final isSelected = _selectedMinistries.contains(ministry);
                          return FilterChip(
                            label: Text(ministry),
                            selected: isSelected,
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  _selectedMinistries.add(ministry);
                                } else {
                                  _selectedMinistries.remove(ministry);
                                }
                              });
                            },
                            showCheckmark: false,
                            labelStyle: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: isSelected ? scheme.onPrimary : scheme.onSurface,
                            ),
                            backgroundColor: scheme.surfaceVariant,
                            selectedColor: scheme.primary,
                            side: BorderSide(
                              color: isSelected ? scheme.primary : scheme.outlineVariant,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            elevation: isSelected ? 1 : 0,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _ecNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Emergency Contact Name',
                        prefixIcon: Icon(Icons.contact_emergency_outlined),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _ecRelationCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Emergency Contact Relationship',
                        prefixIcon: Icon(Icons.group_outlined),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _ecPhoneCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Emergency Contact Number',
                        prefixIcon: Icon(Icons.local_phone_outlined),
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile.adaptive(
                      value: _consent,
                      onChanged: (v) => setState(() => _consent = v),
                      title: const Text('Consent to data use'),
                      subtitle: const Text('I consent to the use of my data for church administration'),
                      secondary: const Icon(Icons.verified_user_outlined),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _submit,
                      icon: const Icon(Icons.check_circle),
                      label: const Text('Save Member'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
