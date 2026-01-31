import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class MembershipFormPage extends StatefulWidget {
  const MembershipFormPage({super.key});

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

  @override
  void initState() {
    super.initState();
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one ministry.')),
      );
      return;
    }

    await FirebaseFirestore.instance.collection('members').add({
      'firstName': _firstNameCtrl.text.trim(),
      'lastName': _lastNameCtrl.text.trim(),
      'phoneNumber': _phoneCtrl.text.trim(),
      'email': _emailCtrl.text.trim(),
      'address': _addressCtrl.text.trim(),
      'preferredContactMethod': _preferredContactCtrl.text.trim(),
      'ministries': _selectedMinistries,
      'emergencyContactName': _ecNameCtrl.text.trim(),
      'emergencyContactRelationship': _ecRelationCtrl.text.trim(),
      'emergencyContactNumber': _ecPhoneCtrl.text.trim(),
      'dateOfBirth': Timestamp.fromDate(_dob!),
      'gender': _gender,
      'consentToDataUse': _consent,
      'isVisitor': _isVisitor,
      'createdByUid': currentUser.uid,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Member registered!')),
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
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _lastNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Last Name *',
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    InkWell(
                      onTap: _pickDob,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Date of Birth *',
                          border: OutlineInputBorder(),
                          filled: true,
                          fillColor: Colors.white,
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
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
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
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      keyboardType: TextInputType.phone,
                      validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _emailCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Email *',
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      keyboardType: TextInputType.emailAddress,
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
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _preferredContactCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Preferred Contact Method',
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      title: const Text('Are you a visitor?'),
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
                        ? const CircularProgressIndicator()
                        : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Select Ministries *', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: _availableMinistries.map((ministry) {
                            return FilterChip(
                              label: Text(ministry),
                              selected: _selectedMinistries.contains(ministry),
                              onSelected: (selected) {
                                setState(() {
                                  if (selected) {
                                    _selectedMinistries.add(ministry);
                                  } else {
                                    _selectedMinistries.remove(ministry);
                                  }
                                });
                              },
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _ecNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Emergency Contact Name',
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _ecRelationCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Emergency Contact Relationship',
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _ecPhoneCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Emergency Contact Number',
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      value: _consent,
                      onChanged: (v) => setState(() => _consent = v ?? false),
                      title: const Text('I consent to data use and communication.'),
                      controlAffinity: ListTileControlAffinity.leading,
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
