import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Collection name used by Cloud Function onCreate trigger to notify pastors.
const String _kPrayerRequestsCol = 'prayerRequests';

class PrayerRequestFormPage extends StatefulWidget {
  const PrayerRequestFormPage({super.key});

  @override
  State<PrayerRequestFormPage> createState() => _PrayerRequestFormPageState();
}

class _PrayerRequestFormPageState extends State<PrayerRequestFormPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();

  bool _isAnonymous = false;
  bool _submitting = false;

  String? _uid;
  String? _linkedMemberId;

  @override
  void initState() {
    super.initState();
    _preloadUserBits();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _preloadUserBits() async {
    final user = _auth.currentUser;
    if (user == null) return;
    setState(() {
      _uid = user.uid;
      _emailCtrl.text = user.email ?? _emailCtrl.text;
    });

    try {
      // Try to pull memberId and full name to prefill.
      final userSnap = await _db.collection('users').doc(user.uid).get();
      final u = userSnap.data() ?? {};
      final memberId = (u['memberId'] ?? '').toString();
      if (memberId.isNotEmpty) {
        setState(() => _linkedMemberId = memberId);
        final mem = await _db.collection('members').doc(memberId).get();
        if (mem.exists) {
          final m = mem.data() as Map<String, dynamic>;
          final full = (m['fullName'] ?? '').toString().trim();
          final fn = (m['firstName'] ?? '').toString().trim();
          final ln = (m['lastName'] ?? '').toString().trim();
          final composed = full.isNotEmpty ? full : [fn, ln].where((s) => s.isNotEmpty).join(' ').trim();
          if (composed.isNotEmpty && mounted && _nameCtrl.text.trim().isEmpty) {
            _nameCtrl.text = composed;
          }
          if ((m['email'] ?? '').toString().isNotEmpty && mounted && _emailCtrl.text.trim().isEmpty) {
            _emailCtrl.text = (m['email'] ?? '').toString();
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _ensureSignedIn() async {
    // Allow everyone to submit + view their own: if not signed in, sign in anonymously.
    if (_auth.currentUser != null) return;
    final cred = await _auth.signInAnonymously();
    setState(() => _uid = cred.user?.uid);
  }

  Query<Map<String, dynamic>>? _myRequestsQuery() {
    if (_uid == null || _uid!.isEmpty) return null;
    return _db
        .collection(_kPrayerRequestsCol)
        .where('requestedByUid', isEqualTo: _uid)
        .orderBy('requestedAt', descending: true);
  }

  String _fmtTs(dynamic ts) {
    try {
      final t = (ts as Timestamp).toDate().toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    } catch (_) {
      return '';
    }
  }

  Color _statusColor(String s, BuildContext ctx) {
    final theme = Theme.of(ctx).colorScheme;
    switch (s.toLowerCase()) {
      case 'new':
      case 'pending':
        return theme.primary.withOpacity(.15);
      case 'prayed':
        return theme.secondary.withOpacity(.18);
      case 'archived':
      default:
        return theme.surfaceVariant.withOpacity(.5);
    }
  }

  Widget _statusChip(String? status) {
    final s = (status ?? 'new').toString();
    return Chip(
      label: Text(s),
      visualDensity: const VisualDensity(vertical: -4),
    );
    // If you want colored backgrounds:
    // return Container(
    //   decoration: BoxDecoration(
    //     color: _statusColor(s, context),
    //     borderRadius: BorderRadius.circular(999),
    //   ),
    //   padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    //   child: Text(s, style: const TextStyle(fontSize: 12)),
    // );
  }

  Future<void> _submit() async {
    if (_submitting) return;

    if (!_isAnonymous) {
      if (!_formKey.currentState!.validate()) return;
    } else {
      // For anonymous requests we still require a message.
      if (_messageCtrl.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter your prayer request.')),
        );
        return;
      }
    }

    setState(() => _submitting = true);
    try {
      await _ensureSignedIn();

      final now = FieldValue.serverTimestamp();
      final map = <String, dynamic>{
        'message': _messageCtrl.text.trim(),
        'isAnonymous': _isAnonymous,
        'requestedAt': now,
        'updatedAt': now,
          'status': 'pending', // pending | prayed | archived
      };


      // Attach identity hints if not anonymous
      if (!_isAnonymous) {
        final name = _nameCtrl.text.trim();
        final email = _emailCtrl.text.trim();
        if (name.isNotEmpty) map['name'] = name;
        if (email.isNotEmpty) map['email'] = email;
      }

      // Link requester where possible
      if (_uid != null && _uid!.isNotEmpty) {
        map['requestedByUid'] = _uid;
      }
      if (_linkedMemberId != null && _linkedMemberId!.isNotEmpty) {
        map['requesterMemberId'] = _linkedMemberId;
      }

      await _db.collection(_kPrayerRequestsCol).add(map);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Prayer request submitted')),
      );
      _formKey.currentState?.reset();
      _messageCtrl.clear();
      if (_isAnonymous) {
        _nameCtrl.clear();
        _emailCtrl.clear();
      }
      setState(() {
        _isAnonymous = false;
      });
    } on FirebaseException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Failed to submit: ${e.message ?? e.code}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Failed to submit: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
  Future<void> _deleteRequest(String docId) async {
    await _db.collection(_kPrayerRequestsCol).doc(docId).delete();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('🗑️ Request deleted')),
    );
  }

  Future<void> _editRequest(String docId, String currentMessage) async {
    final ctrl = TextEditingController(text: currentMessage);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit request'),
        content: TextField(
          controller: ctrl,
          minLines: 4, maxLines: 8,
          decoration: const InputDecoration(
            border: OutlineInputBorder(), hintText: 'Update your request',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (res == null || res.isEmpty) return;

    await _db.collection(_kPrayerRequestsCol).doc(docId).update({
      'message': res,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✏️ Request updated')),
    );
  }


  @override
  Widget build(BuildContext context) {
    final canEditIdentity = !_isAnonymous;
    final q = _myRequestsQuery();

    return Scaffold(
      appBar: AppBar(title: const Text('Prayer Request')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ===== FORM =====
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SwitchListTile(
                        value: _isAnonymous,
                        onChanged: (v) => setState(() => _isAnonymous = v),
                        title: const Text('Submit anonymously'),
                        subtitle: const Text("If enabled, your name and email won't be shown to pastors."),
                      ),
                      const SizedBox(height: 12),

                      TextFormField(
                        controller: _nameCtrl,
                        enabled: canEditIdentity,
                        decoration: const InputDecoration(
                          labelText: 'Name (optional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),

                      TextFormField(
                        controller: _emailCtrl,
                        enabled: canEditIdentity,
                        decoration: const InputDecoration(
                          labelText: 'Email (optional)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        validator: (v) {
                          if (!canEditIdentity) return null;
                          final s = (v ?? '').trim();
                          if (s.isEmpty) return null;
                          final ok = RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(s);
                          return ok ? null : 'Enter a valid email';
                        },
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: _messageCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Your prayer request',
                          border: OutlineInputBorder(),
                        ),
                        minLines: 5,
                        maxLines: 10,
                        validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Please enter your prayer request' : null,
                      ),
                      const SizedBox(height: 16),

                      FilledButton.icon(
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send),
                        label: const Text('Submit'),
                      ),

                      const SizedBox(height: 12),
                      const Text(
                        'Pastors receive a notification when you submit.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 8),

                // ===== MY REQUESTS =====
                Row(
                  children: [
                    const Icon(Icons.history),
                    const SizedBox(width: 8),
                    Text('My requests', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    if (_uid == null)
                      TextButton.icon(
                        onPressed: () async {
                          await _ensureSignedIn();
                          setState(() {}); // re-build to attach the stream
                        },
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in to view'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                if (_uid != null && q != null)
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: q.snapshots(),
                    builder: (context, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (snap.hasError) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text('Error loading your requests: ${snap.error}'),
                        );
                      }
                      final docs = snap.data?.docs ?? const [];
                      if (docs.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('You have not submitted any requests yet.'),
                        );
                      }

                      return ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final doc = docs[i];
                          final data = doc.data();
                          final id = doc.id;

                          final msg = (data['message'] ?? '').toString();
                          final ts = data['requestedAt'];
                          final when = _fmtTs(ts);
                          final status = (data['status'] ?? 'pending').toString();
                          final isAnon = data['isAnonymous'] == true;
                          final name = (data['name'] ?? '').toString();
                          final email = (data['email'] ?? '').toString();
                          final mine = (data['requestedByUid'] ?? '') == _uid;
                          final canAct = mine && status.toLowerCase() == 'pending';

                          return Material(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.circular(12),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () {},
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            when.isNotEmpty ? when : '—',
                                            style: Theme.of(context).textTheme.bodySmall,
                                          ),
                                        ),
                                        _statusChip(status),
                                        if (canAct) ...[
                                          const SizedBox(width: 4),
                                          PopupMenuButton<String>(
                                            onSelected: (v) async {
                                              if (v == 'edit') await _editRequest(id, msg);
                                              if (v == 'delete') await _deleteRequest(id);
                                            },
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                                              PopupMenuItem(value: 'delete', child: Text('Delete')),
                                            ],
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Text(msg, style: Theme.of(context).textTheme.bodyMedium),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        Icon(isAnon ? Icons.visibility_off : Icons.person, size: 16),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            isAnon
                                                ? 'Anonymous'
                                                : [name, email].where((s) => s.trim().isNotEmpty).join(' • ').trim().isNotEmpty
                                                ? [name, email].where((s) => s.trim().isNotEmpty).join(' • ')
                                                : 'You',
                                            style: Theme.of(context).textTheme.bodySmall,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },

                      );
                    },
                  )
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('Sign in to view your past requests.'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
