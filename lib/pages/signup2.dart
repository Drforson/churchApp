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
  final _authService = AuthService();
  final _formKey = GlobalKey<FormState>();

  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneNumberController = TextEditingController();
  String? _selectedGender;
  DateTime? _selectedDate;
  List<String> _ministries = [];

  bool _loading = false;
  bool _preloading = true;
  bool _phoneNumberConflict = false;
  bool _emailConflict = false;
  bool _isExistingMember = false;

  String? _existingMemberId;

  @override
  void initState() {
    super.initState();
    _loadMemberData();
  }

  Future<void> _loadMemberData() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('members')
          .where('email', isEqualTo: widget.email)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        final doc = snapshot.docs.first;
        final data = doc.data();
        setState(() {
          _existingMemberId = doc.id;
          _firstNameController.text = data['firstName'] ?? '';
          _lastNameController.text = data['lastName'] ?? '';
          _phoneNumberController.text = data['phoneNumber'] ?? '';
          _selectedGender = data['gender'];
          final dobTimestamp = data['dateOfBirth'];
          if (dobTimestamp != null) {
            _selectedDate = (dobTimestamp as Timestamp).toDate();
          }
          _ministries = List<String>.from(data['ministries'] ?? []);
          _isExistingMember = true;
        });
      }
    } catch (e) {
      print('⚠️ Error preloading member data: $e');
    } finally {
      setState(() {
        _preloading = false;
      });
    }
  }

  bool get _isFormValid {
    return _formKey.currentState?.validate() == true &&
        _selectedGender != null &&
        _selectedDate != null &&
        !_phoneNumberConflict &&
        !_emailConflict;
  }

  Future<void> _checkPhoneNumberConflict(String phoneNumber) async {
    if (phoneNumber.isEmpty) {
      setState(() => _phoneNumberConflict = false);
      return;
    }

    final snapshot = await _authService.checkPhoneNumberExists(phoneNumber);
    setState(() {
      _phoneNumberConflict = snapshot;
    });
  }

  Future<void> _checkEmailConflict(String email) async {
    if (email.isEmpty) {
      setState(() => _emailConflict = false);
      return;
    }

    final snapshot = await FirebaseFirestore.instance
        .collection('members')
        .where('email', isEqualTo: email)
        .get();

    bool conflict = false;
    for (var doc in snapshot.docs) {
      if (doc.id != _existingMemberId) {
        conflict = true;
        break;
      }
    }

    setState(() {
      _emailConflict = conflict;
    });
  }

  Future<void> _submit() async {
    if (!_isFormValid) return;

    setState(() => _loading = true);

    try {
      if (_isExistingMember && _existingMemberId != null) {
        await FirebaseFirestore.instance.collection('members').doc(_existingMemberId).update({
          'firstName': _firstNameController.text.trim(),
          'lastName': _lastNameController.text.trim(),
          'phoneNumber': _phoneNumberController.text.trim(),
          'gender': _selectedGender,
          'dateOfBirth': Timestamp.fromDate(_selectedDate!),
        });

        await FirebaseFirestore.instance.collection('users').doc(widget.uid).update({
          'memberId': _existingMemberId,
        });
      } else {
        final memberRef = FirebaseFirestore.instance.collection('members').doc();
        await memberRef.set({
          'id': memberRef.id,
          'firstName': _firstNameController.text.trim(),
          'lastName': _lastNameController.text.trim(),
          'email': widget.email,
          'phoneNumber': _phoneNumberController.text.trim(),
          'gender': _selectedGender,
          'dateOfBirth': Timestamp.fromDate(_selectedDate!),
          'ministries': [],
          'createdAt': FieldValue.serverTimestamp(),
        });

        await FirebaseFirestore.instance.collection('users').doc(widget.uid).update({
          'memberId': memberRef.id,
        });
      }

      await FirebaseAuth.instance.currentUser?.getIdToken(true);

      Navigator.pushReplacementNamed(context, '/success');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _loading = false);
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
    return _loading
        ? Container(
      color: Colors.black.withOpacity(0.5),
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    )
        : const SizedBox();
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
                        style: TextStyle(color: Colors.green, fontWeight: FontWeight.w600),
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
                        style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600),
                      ),
                    ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _firstNameController,
                    decoration: const InputDecoration(labelText: 'First Name'),
                    validator: (val) => val == null || val.isEmpty ? 'First name is required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _lastNameController,
                    decoration: const InputDecoration(labelText: 'Last Name'),
                    validator: (val) => val == null || val.isEmpty ? 'Last name is required' : null,
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
                      if (value.length >= 9) {
                        _checkPhoneNumberConflict(value.trim());
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
                    validator: (val) => val == null ? 'Please select gender' : null,
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: _selectDate,
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Date of Birth'),
                      child: Text(
                        _selectedDate == null
                            ? 'Select Date'
                            : DateFormat('dd/MM/yyyy').format(_selectedDate!),
                        style: TextStyle(
                          color: _selectedDate == null ? Colors.grey : Colors.black,
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
                        const Text('Ministries:', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        ..._ministries.map((ministry) => Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(ministry, style: const TextStyle(color: Colors.blue)),
                        )),
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Complete Signup', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
          ),
        ),
        buildLoadingOverlay(), // 🔥
      ],
    );
  }
}
