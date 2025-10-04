import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class PrayerRequestFormPage extends StatefulWidget {
  const PrayerRequestFormPage({super.key});

  @override
  State<PrayerRequestFormPage> createState() => _PrayerRequestFormPageState();
}

class _PrayerRequestFormPageState extends State<PrayerRequestFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();

  String? _memberId;
  String? _memberName;
  bool _shareWithTeam = true;
  bool _isUrgent = false;
  bool _loading = true;
  bool _submitting = false;

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
    _titleCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
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

    setState(() => _submitting = true);
    try {
      await FirebaseFirestore.instance.collection('prayerRequests').add({
        'memberId': _memberId,
        'memberName': _memberName,          // snapshot for convenience
        'requestedByUid': u.uid,
        'title': _titleCtrl.text.trim(),
        'message': _messageCtrl.text.trim(),
        'shareWithTeam': _shareWithTeam,
        'urgent': _isUrgent,
        'status': 'open',
        'createdAt': Timestamp.now(),
        'source': 'app',
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Prayer request submitted')));
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
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Prayer Request')),
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
                TextFormField(
                  controller: _titleCtrl,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Subject / Title (optional)'),
                ),
                TextFormField(
                  controller: _messageCtrl,
                  maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Prayer request *'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter your request' : null,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Share with prayer team'),
                  value: _shareWithTeam,
                  onChanged: (v) => setState(() => _shareWithTeam = v),
                ),
                SwitchListTile(
                  title: const Text('Mark as urgent'),
                  value: _isUrgent,
                  onChanged: (v) => setState(() => _isUrgent = v),
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
