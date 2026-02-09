import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter_google_places_sdk/flutter_google_places_sdk.dart';
import 'package:church_management_app/services/auth_service.dart';
import 'package:church_management_app/secrets.dart';

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

  FlutterGooglePlacesSdk? _places;
  final List<AutocompletePrediction> _addressPredictions = [];
  Place? _selectedAddressPlace;
  String? _selectedAddressPlaceId;
  double? _selectedAddressLat;
  double? _selectedAddressLng;
  Timer? _addrDebounce;
  bool _settingAddressText = false;

  DateTime? _dob;

  bool _initialLoading = true;
  bool _saving = false;
  bool _formValid = false;
  bool _phoneConflict = false;

  String? _originalPhone;

  @override
  void initState() {
    super.initState();
    if (kGooglePlacesApiKey.isNotEmpty) {
      _places = FlutterGooglePlacesSdk(kGooglePlacesApiKey);
      _addressController.addListener(_onAddressChanged);
    }
    _loadProfile();
  }

  @override
  void dispose() {
    _addressController.removeListener(_onAddressChanged);
    _addrDebounce?.cancel();
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
        _settingAddressText = true;
        _addressController.text = (data['address'] ?? '').toString();
        _settingAddressText = false;
        _selectedAddressPlaceId = (data['addressPlaceId'] ?? '').toString().trim();
        if (_selectedAddressPlaceId != null && _selectedAddressPlaceId!.isEmpty) {
          _selectedAddressPlaceId = null;
        }
        _selectedAddressLat = (data['addressLat'] is num) ? (data['addressLat'] as num).toDouble() : null;
        _selectedAddressLng = (data['addressLng'] is num) ? (data['addressLng'] as num).toDouble() : null;

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

  void _onAddressChanged() {
    if (_settingAddressText || _places == null) return;
    final q = _addressController.text.trim();
    if (q.isEmpty) {
      setState(() {
        _addressPredictions.clear();
        _selectedAddressPlace = null;
        _selectedAddressPlaceId = null;
        _selectedAddressLat = null;
        _selectedAddressLng = null;
      });
      return;
    }

    if (_selectedAddressPlace != null || _selectedAddressPlaceId != null) {
      setState(() {
        _selectedAddressPlace = null;
        _selectedAddressPlaceId = null;
        _selectedAddressLat = null;
        _selectedAddressLng = null;
      });
    }

    _debouncedFindAddressPredictions(q);
  }

  void _debouncedFindAddressPredictions(String query) {
    if (_places == null) return;
    _addrDebounce?.cancel();
    _addrDebounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final res = await _places!.findAutocompletePredictions(
          query,
          countries: const ['GB', 'US', 'NG', 'ZA', 'KE'],
          newSessionToken: true,
        );
        if (!mounted) return;
        setState(() {
          _addressPredictions
            ..clear()
            ..addAll(res.predictions);
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _addressPredictions.clear());
      }
    });
  }

  Future<void> _selectAddressPrediction(AutocompletePrediction p) async {
    if (_places == null) return;
    try {
      final det = await _places!.fetchPlace(
        p.placeId,
        fields: const [
          PlaceField.Address,
          PlaceField.Id,
          PlaceField.Location,
          PlaceField.Name,
        ],
      );
      if (!mounted) return;
      final place = det.place;
      final display = place?.address ?? place?.name ?? _addressController.text;
      _settingAddressText = true;
      _addressController.text = display;
      _settingAddressText = false;
      setState(() {
        _selectedAddressPlace = place;
        _selectedAddressPlaceId = p.placeId;
        _selectedAddressLat = place?.latLng?.lat;
        _selectedAddressLng = place?.latLng?.lng;
        _addressPredictions.clear();
      });
    } catch (e) {
      if (!mounted) return;
      Fluttertoast.showToast(
        msg: "Failed to get address: $e",
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Colors.redAccent,
        textColor: Colors.white,
      );
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
      final addressText = _addressController.text.trim();
      final selectedPlaceId = _selectedAddressPlaceId ?? _selectedAddressPlace?.id;
      final selectedLat = _selectedAddressLat ?? _selectedAddressPlace?.latLng?.lat;
      final selectedLng = _selectedAddressLng ?? _selectedAddressPlace?.latLng?.lng;
      if (kGooglePlacesApiKey.isNotEmpty &&
          addressText.isNotEmpty &&
          (selectedPlaceId == null || selectedPlaceId.isEmpty)) {
        Fluttertoast.showToast(
          msg: "Please select the address from the suggestions.",
          toastLength: Toast.LENGTH_LONG,
          gravity: ToastGravity.TOP,
          backgroundColor: Colors.redAccent,
          textColor: Colors.white,
        );
        setState(() => _saving = false);
        return;
      }

      final first = _firstNameController.text.trim();
      final last = _lastNameController.text.trim();
      final fullName =
      [first, last].where((s) => s.isNotEmpty).join(' ').trim();

      final payload = <String, dynamic>{
        'firstName': first,
        'lastName': last,
        'fullName': fullName,
        'phoneNumber': _phoneController.text.trim(),
        'address': addressText,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (addressText.isEmpty) {
        payload['addressPlaceId'] = FieldValue.delete();
        payload['addressLat'] = FieldValue.delete();
        payload['addressLng'] = FieldValue.delete();
      } else {
        if (selectedPlaceId != null && selectedPlaceId.isNotEmpty) {
          payload['addressPlaceId'] = selectedPlaceId;
        }
        if (selectedLat != null) payload['addressLat'] = selectedLat;
        if (selectedLng != null) payload['addressLng'] = selectedLng;
      }

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
              if (kGooglePlacesApiKey.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Google Places API key is missing. Address search will be manual.',
                    style: TextStyle(fontSize: 12, color: Colors.redAccent),
                  ),
                ),
              TextFormField(
                controller: _addressController,
                decoration: const InputDecoration(labelText: "Address"),
              ),
              if (_addressPredictions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.white,
                  ),
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _addressPredictions.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final p = _addressPredictions[i];
                      return ListTile(
                        leading: const Icon(Icons.location_on),
                        title: Text(p.primaryText),
                        subtitle: p.secondaryText != null ? Text(p.secondaryText!) : null,
                        onTap: () => _selectAddressPrediction(p),
                      );
                    },
                  ),
                ),
              ],
              if (_selectedAddressLat != null && _selectedAddressLng != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Selected: ${_addressController.text.trim()}\n'
                        'Lat: ${_selectedAddressLat!.toStringAsFixed(6)}, '
                        'Lng: ${_selectedAddressLng!.toStringAsFixed(6)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
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
