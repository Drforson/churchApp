import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class BaptismInterestFormPage extends StatefulWidget {
  const BaptismInterestFormPage({super.key});

  @override
  State<BaptismInterestFormPage> createState() => _BaptismInterestFormPageState();
}

class _BaptismInterestFormPageState extends State<BaptismInterestFormPage> {
  final _formKey = GlobalKey<FormState>();

  String? _memberId;
  String? _memberName;

  String? _gender;            // required
  DateTime? _birthDate;       // required (for age calc in manage page)
  String? _season;            // required: winter/spring/summer/autumn
  final _notesCtrl = TextEditingController();

  bool _consent = false;
  bool _loading = true;
  bool _submitting = false;

  static const _seasons = <String>['winter', 'spring', 'summer', 'autumn'];

  @override
  void initState() {
    super.initState();
    _prefillFromMember();
  }

  Future<void> _prefillFromMember() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      setState(() => _loading = false);
      return;
    }
    final uDoc = await FirebaseFirestore.instance.collection('users').doc(u.uid).get();
    final memberId = (uDoc.data() ?? const {})['memberId'] as String?;
    String? memberName;

    if (memberId != null) {
      final mDoc = await FirebaseFirestore.instance.collection('members').doc(memberId).get();
      final md = mDoc.data() ?? {};
      memberName = (md['fullName'] ??
          [md['firstName'], md['lastName']]
              .where((e) => (e ?? '').toString().trim().isNotEmpty)
              .join(' '))
          .toString()
          .trim();
    }

    setState(() {
      _memberId = memberId;
      _memberName = (memberName == null || memberName.isEmpty) ? 'Member' : memberName;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final first = DateTime(now.year - 100, now.month, now.day);
    final last = now;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(now.year - 18),
      firstDate: first,
      lastDate: last,
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  Future<void> _submit() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please sign in to submit.')));
      return;
    }
    if (_memberId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Your profile isn’t linked to a member record yet.')));
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    if (!_consent) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please confirm your request.')));
      return;
    }

    setState(() => _submitting = true);
    try {
      await FirebaseFirestore.instance.collection('baptismRequests').add({
        'memberId': _memberId,
        'memberName': _memberName,                 // snapshot for convenience
        'requestedByUid': u.uid,
        'gender': _gender,
        'birthDate': _birthDate != null ? Timestamp.fromDate(_birthDate!) : null,
        'season': _season,                          // <-- season instead of preferredDate
        'notes': _notesCtrl.text.trim(),
        'status': 'pending',
        'requestedAt': Timestamp.now(),
        'source': 'app',
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Baptism request submitted')));
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Submission failed: $e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      appBar: AppBar(title: const Text('Baptism Interest')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (_memberName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Row(
                children: [
                  const Icon(Icons.person, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('Submitting as: $_memberName',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          Form(
            key: _formKey,
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  value: _gender,
                  items: const [
                    DropdownMenuItem(value: 'male', child: Text('Male')),
                    DropdownMenuItem(value: 'female', child: Text('Female')),
                    DropdownMenuItem(value: 'other', child: Text('Other / Prefer not to say')),
                  ],
                  decoration: const InputDecoration(labelText: 'Gender *'),
                  onChanged: (v) => setState(() => _gender = v),
                  validator: (v) => v == null ? 'Select your gender' : null,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _birthDate == null
                            ? 'Birth date *'
                            : 'Birth date: ${_birthDate!.toLocal().toString().split(' ').first}',
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _pickBirthDate,
                      icon: const Icon(Icons.cake_outlined),
                      label: const Text('Pick'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _season,
                  items: _seasons
                      .map((s) => DropdownMenuItem(value: s, child: Text(s[0].toUpperCase() + s.substring(1))))
                      .toList(),
                  decoration: const InputDecoration(labelText: 'Preferred season *'),
                  onChanged: (v) => setState(() => _season = v),
                  validator: (v) => v == null ? 'Select a season' : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _notesCtrl,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Notes / Testimony (optional)'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _consent,
                  onChanged: (v) => setState(() => _consent = v ?? false),
                  title: const Text('I confirm my desire to be baptised.'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: const Icon(Icons.send),
                    label: Text(_submitting ? 'Submitting...' : 'Submit request'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
