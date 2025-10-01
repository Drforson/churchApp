import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';

class EditProfilePage extends StatefulWidget {
  final String memberId;

  const EditProfilePage({super.key, required this.memberId});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final _formKey = GlobalKey<FormState>();

  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  DateTime? _dob;

  bool _loading = false;
  bool _formValid = false;
  bool _phoneConflict = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final doc = await FirebaseFirestore.instance.collection('members').doc(widget.memberId).get();
    final data = doc.data();
    if (data != null) {
      _firstNameController.text = data['firstName'] ?? '';
      _lastNameController.text = data['lastName'] ?? '';
      _phoneController.text = data['phoneNumber'] ?? '';
      _addressController.text = data['address'] ?? '';
      if (data['dob'] != null) {
        _dob = (data['dob'] as Timestamp).toDate();
      }
      _validateForm();
      setState(() {});
    }
  }

  Future<void> _pickDateOfBirth() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (pickedDate != null) {
      setState(() {
        _dob = pickedDate;
      });
      _validateForm();
    }
  }

  Future<void> _checkPhoneNumberConflict(String phoneNumber) async {
    if (phoneNumber.isEmpty) {
      setState(() {
        _phoneConflict = false;
        _formValid = _formKey.currentState?.validate() ?? false;
      });
      return;
    }

    final phoneQuery = await FirebaseFirestore.instance
        .collection('members')
        .where('phoneNumber', isEqualTo: phoneNumber)
        .get();

    final conflict = phoneQuery.docs.any((doc) => doc.id != widget.memberId);

    setState(() {
      _phoneConflict = conflict;
      _formValid = (_formKey.currentState?.validate() ?? false) && !conflict;
    });
  }

  void _validateForm() {
    final formState = _formKey.currentState;
    if (formState == null) return;

    final isValid = formState.validate();
    setState(() {
      _formValid = isValid && !_phoneConflict;
    });
  }

  Future<void> _saveProfile() async {
    if (!_formValid) return;

    setState(() => _loading = true);

    try {
      await FirebaseFirestore.instance.collection('members').doc(widget.memberId).update({
        'firstName': _firstNameController.text.trim(),
        'lastName': _lastNameController.text.trim(),
        'phoneNumber': _phoneController.text.trim(),
        'address': _addressController.text.trim(),
        'dob': _dob != null ? Timestamp.fromDate(_dob!) : null,
      });

      Fluttertoast.showToast(
        msg: "Profile updated successfully!",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Colors.green,
        textColor: Colors.white,
        fontSize: 16.0,
      );

      Navigator.pop(context); // Go back to HomePage
    } catch (e) {
      Fluttertoast.showToast(
        msg: "Error: $e",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Colors.redAccent,
        textColor: Colors.white,
        fontSize: 16.0,
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          onChanged: _validateForm,
          child: Column(
            children: [
              TextFormField(
                controller: _firstNameController,
                decoration: const InputDecoration(labelText: "First Name"),
                validator: (value) => value == null || value.isEmpty ? "Please enter your first name" : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _lastNameController,
                decoration: const InputDecoration(labelText: "Last Name"),
                validator: (value) => value == null || value.isEmpty ? "Please enter your last name" : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                decoration: InputDecoration(
                  labelText: "Phone Number",
                  suffixIcon: _phoneConflict
                      ? const Icon(Icons.error, color: Colors.red)
                      : const Icon(Icons.check_circle, color: Colors.green),
                ),
                onChanged: (value) => _checkPhoneNumberConflict(value.trim()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _addressController,
                decoration: const InputDecoration(labelText: "Address"),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: _pickDateOfBirth,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: "Date of Birth",
                    prefixIcon: Icon(Icons.calendar_today),
                  ),
                  child: Text(
                    _dob == null ? 'Select your birthdate' : '${_dob!.toLocal()}'.split(' ')[0],
                    style: TextStyle(color: _dob == null ? Colors.grey : Colors.black87),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                icon: _loading
                    ? const CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.0,
                )
                    : const Icon(Icons.save, color: Colors.white),
                label: const Text("Save Changes", style: TextStyle(color: Colors.white)),
                onPressed: _formValid && !_loading ? _saveProfile : null,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: Colors.indigo[700],
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
