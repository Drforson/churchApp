// lib/pages/ministries_page.dart
import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class MinistriesPage extends StatefulWidget {
  const MinistriesPage({super.key});

  @override
  State<MinistriesPage> createState() => _MinistriesPageState();
}

class _MinistriesPageState extends State<MinistriesPage>
    with TickerProviderStateMixin {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  bool _loading = true;
  bool _isLeader = false;
  String? _uid;
  String? _memberId;

  Map<String, dynamic> _claims = {};
  Map<String, dynamic>? _userDoc;
  Map<String, dynamic>? _memberDoc;

  // UI
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        setState(() {
          _loading = false;
          _isLeader = false;
        });
        return;
      }
      _uid = user.uid;

      // force refresh claims
      final token = await user.getIdTokenResult(true);
      _claims = token.claims ?? {};

      // fetch users doc
      final userSnap = await _db.collection('users').doc(_uid).get();
      _userDoc = userSnap.data();

      // memberId
      _memberId = _userDoc?['memberId'];

      // fetch member doc if any
      if (_memberId != null) {
        final memSnap = await _db.collection('members').doc(_memberId).get();
        _memberDoc = memSnap.data();
      }

      bool isLeaderByClaim = (_claims['leader'] == true) || (_claims['isLeader'] == true);
      List rolesUser = (_userDoc?['roles'] is List) ? List.from(_userDoc!['roles']) : const [];
      List rolesMember = (_memberDoc?['roles'] is List) ? List.from(_memberDoc!['roles']) : const [];
      List lmUser = (_userDoc?['leadershipMinistries'] is List) ? List.from(_userDoc!['leadershipMinistries']) : const [];
      List lmMember = (_memberDoc?['leadershipMinistries'] is List) ? List.from(_memberDoc!['leadershipMinistries']) : const [];

      bool isLeader = isLeaderByClaim
          || rolesUser.map((e) => e.toString().toLowerCase()).contains('leader')
          || rolesMember.map((e) => e.toString().toLowerCase()).contains('leader')
          || lmUser.isNotEmpty
          || lmMember.isNotEmpty;

      // Console debug
      // ignore: avoid_print
      print('[MinistriesPage] bootstrap'
          '\n  uid=$_uid'
          '\n  claims=${jsonEncode(_claims)}'
          '\n  users.roles=$rolesUser'
          '\n  users.leadershipMinistries=$lmUser'
          '\n  memberId=$_memberId'
          '\n  members.roles=$rolesMember'
          '\n  members.leadershipMinistries=$lmMember'
          '\n  -> isLeader=$isLeader');

      setState(() {
        _isLeader = isLeader;
        _loading = false;
      });
    } catch (e, st) {
      // ignore: avoid_print
      print('[MinistriesPage] bootstrap error: $e\n$st');
      setState(() {
        _isLeader = false;
        _loading = false;
      });
    }
  }

  // -------- New Ministry Request (Leader) --------
  Future<void> _openNewMinistryDialog() async {
    _nameCtrl.clear();
    _descCtrl.clear();

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Request a new ministry'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Ministry name',
                  hintText: 'e.g., Ushers, Choir, Media...',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 8),
              Text(
                'A request will be sent to Pastors/Admins for approval.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: _submitRequest,
              icon: const Icon(Icons.send),
              label: const Text('Submit'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _submitRequest() async {
    final name = _nameCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a ministry name')),
      );
      return;
    }

    final uid = _auth.currentUser?.uid;
    if (uid == null) return;

    final payload = <String, dynamic>{
      'name': name,
      'description': desc,
      'requestedByUid': uid,                 // required by rules
      'requesterMemberId': _memberId,        // helps rules if users.memberId missing
      'status': 'pending',                   // enforced by rules if provided
      'createdAt': FieldValue.serverTimestamp(),
    };

    // Console dump before write
    // ignore: avoid_print
    print('[MinistryRequest] attempting create payload=${jsonEncode(payload)}');

    try {
      await _db.collection('ministry_creation_requests').add(payload);
      if (mounted) {
        Navigator.of(context).pop(); // close dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Request submitted for "$name"')),
        );
      }
    } on FirebaseException catch (e, st) {
      // ignore: avoid_print
      print('[MinistryRequest] FirebaseException code=${e.code} message=${e.message}\n$st');
      if (mounted) {
        _showDebugSheet(
          title: 'Permission error',
          message:
          'Code: ${e.code}\nMessage: ${e.message}\n\nWe will show your current claims, users/members docs, and the exact payload we tried to send.',
          payload: payload,
        );
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('[MinistryRequest] error: $e\n$st');
      if (mounted) {
        _showDebugSheet(
          title: 'Unexpected error',
          message: e.toString(),
          payload: payload,
        );
      }
    }
  }

  void _showDebugSheet({
    required String title,
    required String message,
    Map<String, dynamic>? payload,
  }) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: SafeArea(
            child: SingleChildScrollView(
              child: DefaultTextStyle(
                style: Theme.of(context).textTheme.bodyMedium!,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(message),
                    const SizedBox(height: 12),
                    _kv('UID', _uid),
                    _kv('Custom claims', const JsonEncoder.withIndent('  ').convert(_claims)),
                    _kv('users doc', const JsonEncoder.withIndent('  ').convert(_userDoc ?? {})),
                    _kv('members doc', const JsonEncoder.withIndent('  ').convert(_memberDoc ?? {})),
                    _kv('payload', const JsonEncoder.withIndent('  ').convert(payload ?? {})),
                    const SizedBox(height: 24),
                    Text(
                      'Rule checklist for create(ministry_creation_requests):\n'
                          '  • signedIn ✅\n'
                          '  • isLeader() OR memberIdIsLeader(requesterMemberId) ✅\n'
                          '  • name: non-empty string ✅\n'
                          '  • requestedByUid == auth.uid OR requesterMemberId == your memberId ✅\n'
                          '  • (if status provided) status == "pending" ✅',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _kv(String k, Object? v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text('$k:\n$v'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fab = (!_loading && _isLeader)
        ? FloatingActionButton.extended(
      onPressed: _openNewMinistryDialog,
      icon: const Icon(Icons.add),
      label: const Text('Request ministry'),
    )
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ministries'),
        actions: [
          IconButton(
            tooltip: 'Debug',
            icon: const Icon(Icons.bug_report),
            onPressed: () => _showDebugSheet(
              title: 'Environment debug',
              message: 'Here is what we know about your auth/roles.',
              payload: const {},
            ),
          ),
        ],
      ),
      floatingActionButton: fab,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    // This is just a simple list of ministries; you can replace with your own UI.
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _db.collection('ministries').orderBy('name').snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snap.data!.docs;
        if (docs.isEmpty) {
          return const Center(child: Text('No ministries yet'));
        }
        return ListView.separated(
          itemCount: docs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final d = docs[i].data();
            return ListTile(
              title: Text(d['name'] ?? '—'),
              subtitle: Text(d['description'] ?? ''),
              leading: const Icon(Icons.groups_2),
            );
          },
        );
      },
    );
  }
}
