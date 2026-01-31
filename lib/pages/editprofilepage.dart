import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:church_management_app/services/auth_service.dart';

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

  bool _initialLoading = true;
  bool _saving = false;
  bool _formValid = false;
  bool _phoneConflict = false;

  String? _originalPhone;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('members')
          .doc(widget.memberId)
          .get();

      final data = doc.data();
      if (data != null) {
        _firstNameController.text = (data['firstName'] ?? '').toString();
        _lastNameController.text = (data['lastName'] ?? '').toString();
        _phoneController.text = (data['phoneNumber'] ?? '').toString();
        _addressController.text = (data['address'] ?? '').toString();

        _originalPhone = _phoneController.text.trim();

        final dobField = data['dateOfBirth'];
        if (dobField is Timestamp) {
          _dob = dobField.toDate();
        }

        _validateForm();
      }
    } catch (e) {
      Fluttertoast.showToast(
        msg: "Failed to load profile: $e",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Colors.redAccent,
        textColor: Colors.white,
      );
    } finally {
      if (!mounted) return;
      setState(() => _initialLoading = false);
    }
  }

  Future<void> _pickDateOfBirth() async {
    final now = DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 20),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (pickedDate != null) {
      setState(() => _dob = pickedDate);
      _validateForm();
    }
  }

  Future<void> _checkPhoneNumberConflict(String phoneNumber) async {
    final trimmed = phoneNumber.trim();

    // If empty → no conflict
    if (trimmed.isEmpty) {
      setState(() {
        _phoneConflict = false;
        _formValid = _formKey.currentState?.validate() ?? false;
      });
      return;
    }

    // If user didn't change the phone → no need to check
    if (_originalPhone != null && trimmed == _originalPhone) {
      setState(() {
        _phoneConflict = false;
        _formValid = _formKey.currentState?.validate() ?? false;
      });
      return;
    }

    try {
      final exists = await AuthService.instance
          .checkPhoneNumberExists(trimmed, excludeMemberId: widget.memberId);
      final conflict = exists;

      if (!mounted) return;
      setState(() {
        _phoneConflict = conflict;
        _formValid = (_formKey.currentState?.validate() ?? false) && !conflict;
      });
    } catch (_) {
      // On error, don't hard-block the user; just clear conflict
      if (!mounted) return;
      setState(() {
        _phoneConflict = false;
        _formValid = _formKey.currentState?.validate() ?? false;
      });
    }
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
    if (!_formValid || _saving) return;

    setState(() => _saving = true);

    try {
      final first = _firstNameController.text.trim();
      final last = _lastNameController.text.trim();
      final fullName =
      [first, last].where((s) => s.isNotEmpty).join(' ').trim();

      final payload = <String, dynamic>{
        'firstName': first,
        'lastName': last,
        'fullName': fullName,
        'phoneNumber': _phoneController.text.trim(),
        'address': _addressController.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (_dob != null) {
        payload['dateOfBirth'] = Timestamp.fromDate(_dob!);
      }

      await FirebaseFirestore.instance
          .collection('members')
          .doc(widget.memberId)
          .update(payload);

      Fluttertoast.showToast(
        msg: "Profile updated successfully!",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Colors.green,
        textColor: Colors.white,
        fontSize: 16.0,
      );

      if (mounted) Navigator.pop(context);
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
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_initialLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final phoneText = _phoneController.text.trim();
    final showPhoneIcon = phoneText.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Edit Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          onChanged: _validateForm,
          child: Column(
            children: [
              TextFormField(
                controller: _firstNameController,
                decoration: const InputDecoration(labelText: "First Name"),
                validator: (value) =>
                value == null || value.trim().isEmpty
                    ? "Please enter your first name"
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _lastNameController,
                decoration: const InputDecoration(labelText: "Last Name"),
                validator: (value) =>
                value == null || value.trim().isEmpty
                    ? "Please enter your last name"
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: "Phone Number",
                  suffixIcon: showPhoneIcon
                      ? (_phoneConflict
                      ? const Icon(Icons.error, color: Colors.red)
                      : const Icon(Icons.check_circle,
                      color: Colors.green))
                      : null,
                ),
                onChanged: (value) => _checkPhoneNumberConflict(value),
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty) return "Please enter your phone number";
                  if (_phoneConflict) {
                    return "This phone number is already in use";
                  }
                  return null;
                },
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
                    border: OutlineInputBorder(),
                  ),
                  child: Text(
                    _dob == null
                        ? 'Select your birthdate'
                        : _dob!.toLocal().toString().split(' ').first,
                    style: TextStyle(
                      color:
                      _dob == null ? Colors.grey : Colors.black87,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                icon: _saving
                    ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.0,
                  ),
                )
                    : const Icon(Icons.save, color: Colors.white),
                label: Text(
                  _saving ? "Saving..." : "Save Changes",
                  style: const TextStyle(color: Colors.white),
                ),
                onPressed: _formValid && !_saving ? _saveProfile : null,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: Colors.indigo[700],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
