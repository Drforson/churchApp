import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:church_management_app/services/auth_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class SignupStep2Page extends StatefulWidget {
  final String uid;
  final String email;

  const SignupStep2Page({super.key, required this.uid, required this.email});

  @override
  State<SignupStep2Page> createState() => _SignupStep2PageState();
}

class _SignupStep2PageState extends State<SignupStep2Page> {
  final _authService = AuthService.instance;
  final _formKey = GlobalKey<FormState>();

  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneNumberController = TextEditingController();

  String? _selectedGender; // UI shows Title-case, store lowercase on write
  DateTime? _selectedDate;
  List<String> _ministries = [];

  bool _loading = false;
  bool _preloading = true;
  bool _phoneNumberConflict = false;
  bool _isExistingMember = false;

  String? _existingMemberId;

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseAuth get _auth => FirebaseAuth.instance;

  @override
  void initState() {
    super.initState();
    _loadMemberData();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneNumberController.dispose();
    super.dispose();
  }

  Future<void> _loadMemberData() async {
    try {
      final emailLc = widget.email.trim().toLowerCase();
      final snapshot = await _db
          .collection('members')
          .where('email', isEqualTo: emailLc)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        final doc = snapshot.docs.first;
        final data = doc.data();
        setState(() {
          _existingMemberId = doc.id;
          _firstNameController.text = (data['firstName'] ?? '') as String;
          _lastNameController.text = (data['lastName'] ?? '') as String;
          _phoneNumberController.text = (data['phoneNumber'] ?? '') as String;

          final g = (data['gender'] ?? '') as String;
          _selectedGender = g.isNotEmpty
              ? g[0].toUpperCase() + g.substring(1).toLowerCase()
              : null; // display Title-case

          final dobTimestamp = data['dateOfBirth'];
          if (dobTimestamp != null && dobTimestamp is Timestamp) {
            _selectedDate = dobTimestamp.toDate();
          }

          _ministries = List<String>.from(data['ministries'] ?? []);
          _isExistingMember = true;
        });
      }
    } catch (e) {
    } finally {
      if (mounted) {
        setState(() {
          _preloading = false;
        });
      }
    }
  }

  bool get _isFormValid {
    return _formKey.currentState?.validate() == true &&
        _selectedGender != null &&
        _selectedDate != null &&
        !_phoneNumberConflict;
  }

  /// Check if phone number is used by a *different* member.
  Future<void> _checkPhoneNumberConflict(String phoneNumber) async {
    final v = phoneNumber.trim();
    if (v.isEmpty) {
      setState(() => _phoneNumberConflict = false);
      return;
    }

    try {
      final exists = await _authService.checkPhoneNumberExists(
        v,
        excludeMemberId: _existingMemberId,
      );
      final conflict = exists;

      if (!mounted) return;
      setState(() => _phoneNumberConflict = conflict);
    } catch (e) {
      // Non-fatal, don't block the flow on read error
      if (!mounted) return;
      setState(() => _phoneNumberConflict = false);
    }
  }

  Future<void> _submit() async {
    if (!_isFormValid) return;

    setState(() => _loading = true);

    try {
      final user = _auth.currentUser;
      final uid = widget.uid;
      final authEmail = (user?.email ?? widget.email).trim().toLowerCase();

      final first = _firstNameController.text.trim();
      final last = _lastNameController.text.trim();
      final fullName = [first, last].where((s) => s.isNotEmpty).join(' ').trim();
      final phone = _phoneNumberController.text.trim();
      final genderLower = (_selectedGender ?? '').toLowerCase().trim();
      final dobTs = Timestamp.fromDate(_selectedDate!);
      final now = FieldValue.serverTimestamp();

      if (_isExistingMember && _existingMemberId != null) {
        final memberId = _existingMemberId!;

        // ✅ 1) Let backend link user <-> member by email / userUid
        //    (ensureUserDoc + syncUserRoleFromMemberOnLogin)
        await _authService.refreshServerRoleAndClaims();

        // At this point, your Cloud Function should have:
        //   users/{uid}.memberId = memberId (via Admin SDK)
        // so Firestore rules see requesterMemberId() == memberId
        // and selfMemberSafeUpdate() will pass.

        // 🚫 DO NOT set memberId from the client; rules forbid it.
        // await _db.collection('users').doc(uid).set({
        //   'memberId': memberId,
        //   'email': authEmail,
        //   'updatedAt': now,
        //   'linkedAt': now,
        // }, SetOptions(merge: true));

        final updatePayload = <String, dynamic>{
          'firstName': first,
          'lastName': last,
          'fullName': fullName,
          'email': authEmail,
          'phoneNumber': phone,
          'gender': genderLower,
          'dateOfBirth': dobTs,
          'updatedAt': now,
        };

        // ✅ This now matches `selfMemberSafeUpdate()` allowlist in rules
        await _db.collection('members').doc(memberId).update(updatePayload);

        // Optional but nice: ask backend to recompute roles/claims after profile update
        await _authService.refreshServerRoleAndClaims();
      } else {
        // ✅ New member: still let AuthService handle everything via Cloud Functions
        await _authService.completeMemberProfile(
          uid: uid,
          email: authEmail,
          firstName: first,
          lastName: last,
          phoneNumber: phone,
          gender: genderLower,
          dateOfBirth: _selectedDate!,
        );

        await _authService.refreshServerRoleAndClaims();
      }

      if (!mounted) return;
      Navigator.pushNamedAndRemoveUntil(context, '/role-gate', (_) => false);
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


  Future<void> _selectDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 18),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Widget buildLoadingOverlay() {
    if (!_loading) return const SizedBox();
    return Container(
      color: Colors.black.withOpacity(0.5),
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_preloading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(title: const Text('Complete Your Profile')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _formKey,
              onChanged: () => setState(() {}),
              child: Column(
                children: [
                  if (_isExistingMember)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '✅ Member data preloaded from database',
                        style: TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '📝 No existing member found. You are creating a new member profile.',
                        style: TextStyle(
                          color: Colors.orange,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),

                  TextFormField(
                    controller: _firstNameController,
                    decoration:
                    const InputDecoration(labelText: 'First Name'),
                    validator: (val) =>
                    val == null || val.isEmpty ? 'First name is required' : null,
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _lastNameController,
                    decoration: const InputDecoration(labelText: 'Last Name'),
                    validator: (val) =>
                    val == null || val.isEmpty ? 'Last name is required' : null,
                  ),
                  const SizedBox(height: 12),

                  TextFormField(
                    controller: _phoneNumberController,
                    decoration: InputDecoration(
                      labelText: 'Phone Number',
                      suffixIcon: _phoneNumberConflict
                          ? const Icon(Icons.warning, color: Colors.red)
                          : const Icon(Icons.check_circle, color: Colors.green),
                    ),
                    keyboardType: TextInputType.phone,
                    onChanged: (value) {
                      final v = value.trim();
                      if (v.length >= 9) {
                        _checkPhoneNumberConflict(v);
                      } else {
                        setState(() => _phoneNumberConflict = false);
                      }
                    },
                    validator: (val) {
                      if (val == null || val.isEmpty) {
                        return 'Phone number is required';
                      }
                      if (_phoneNumberConflict) {
                        return 'Phone number already in use';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(
                    decoration: const InputDecoration(labelText: 'Gender'),
                    items: const [
                      DropdownMenuItem(value: 'Male', child: Text('Male')),
                      DropdownMenuItem(value: 'Female', child: Text('Female')),
                      DropdownMenuItem(value: 'Other', child: Text('Other')),
                    ],
                    value: _selectedGender,
                    onChanged: (value) => setState(() => _selectedGender = value),
                    validator: (val) =>
                    val == null ? 'Please select gender' : null,
                  ),
                  const SizedBox(height: 12),

                  InkWell(
                    onTap: _selectDate,
                    child: InputDecorator(
                      decoration:
                      const InputDecoration(labelText: 'Date of Birth'),
                      child: Text(
                        _selectedDate == null
                            ? 'Select Date'
                            : DateFormat('dd/MM/yyyy').format(_selectedDate!),
                        style: TextStyle(
                          color: _selectedDate == null
                              ? Colors.grey
                              : Colors.black,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  if (_ministries.isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Ministries:',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        ..._ministries.map(
                              (ministry) => Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              ministry,
                              style: const TextStyle(color: Colors.blue),
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    const Text(
                      'No ministries assigned yet.',
                      style: TextStyle(color: Colors.grey),
                    ),

                  const SizedBox(height: 24),

                  ElevatedButton(
                    onPressed: _isFormValid && !_loading ? _submit : null,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 50),
                      backgroundColor: Colors.indigo,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Complete Signup',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        buildLoadingOverlay(),
      ],
    );
  }
}
