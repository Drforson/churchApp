import 'dart:convert';
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class PastorMinistryApprovalsPage extends StatefulWidget {
  const PastorMinistryApprovalsPage({super.key});

  @override
  State<PastorMinistryApprovalsPage> createState() => _PastorMinistryApprovalsPageState();
}

class _PastorMinistryApprovalsPageState extends State<PastorMinistryApprovalsPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  bool _loadingRole = true;
  bool _canView = false;   // pastor || admin
  bool _isPastor = false;  // only pastors can approve/decline (per rules)
  String? _uid;

  Map<String, dynamic> _debug = {};
  final Map<String, String> _nameCache = {};

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _userSub;

  @override
  void initState() {
    super.initState();
    _wireRoleListener();
  }

  @override
  void dispose() {
    _userSub?.cancel();
    _userSub = null;
    super.dispose();
  }

  Future<void> _wireRoleListener() async {
    final user = _auth.currentUser;
    if (user == null) {
      setState(() {
        _uid = null;
        _loadingRole = false;
        _canView = false;
        _isPastor = false;
        _debug = {'reason': 'no-auth-user'};
      });
      return;
    }
    _uid = user.uid;

    _userSub = _db.collection('users').doc(user.uid).snapshots().listen((snap) async {
      final data = snap.data() ?? <String, dynamic>{};
      final rolesLower = <String>{};
      String? memberId = data['memberId'] as String?;

      // users.roles array
      if (data['roles'] is List) {
        for (final v in List.from(data['roles'])) {
          if (v is String && v.trim().isNotEmpty) rolesLower.add(v.trim().toLowerCase());
        }
      }
      // users.role
      if (data['role'] is String && (data['role'] as String).trim().isNotEmpty) {
        rolesLower.add((data['role'] as String).trim().toLowerCase());
      }
      // boolean fallbacks
      if (data['isPastor'] == true) rolesLower.add('pastor');
      if (data['isAdmin'] == true) rolesLower.add('admin');

      // custom claims
      try {
        final token = await user.getIdTokenResult(true);
        final claims = token.claims ?? {};
        if (claims['pastor'] == true || claims['isPastor'] == true) rolesLower.add('pastor');
        if (claims['admin'] == true || claims['isAdmin'] == true) rolesLower.add('admin');
      } catch (_) {}

      var canView = rolesLower.contains('pastor') || rolesLower.contains('admin');
      var isPastor = rolesLower.contains('pastor');
      Map<String, dynamic> memberData = const {};

      // member fallback
      if (!canView && memberId != null && memberId.isNotEmpty) {
        try {
          final mem = await _db.collection('members').doc(memberId).get();
          memberData = mem.data() ?? {};
          final mRoles = (memberData['roles'] as List<dynamic>? ?? const [])
              .map((e) => e.toString().toLowerCase())
              .toSet();
          if (mRoles.contains('admin')) {
            rolesLower.add('admin');
          }
          if (mRoles.contains('pastor') || memberData['isPastor'] == true) {
            rolesLower.add('pastor');
          }
          canView = rolesLower.contains('pastor') || rolesLower.contains('admin');
          isPastor = rolesLower.contains('pastor');
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _canView = canView;
        _isPastor = isPastor; // only pastors can act
        _loadingRole = false;
        _debug = {
          'uid': user.uid,
          'resolvedRolesLower': rolesLower.toList(),
          'canView': canView,
          'isPastor': isPastor,
        };
      });
    });
  }

  Future<String> _resolveRequesterName({
    required String requestedByUid,
    String? fallbackFullName,
    String? fallbackEmail,
  }) async {
    if (_nameCache.containsKey(requestedByUid)) return _nameCache[requestedByUid]!;
    if ((fallbackFullName ?? '').trim().isNotEmpty) {
      _nameCache[requestedByUid] = fallbackFullName!.trim();
      return _nameCache[requestedByUid]!;
    }
    try {
      final u = await _db.collection('users').doc(requestedByUid).get();
      final udata = u.data() ?? {};
      final memberId = (udata['memberId'] ?? '').toString();
      if (memberId.isNotEmpty) {
        final m = await _db.collection('members').doc(memberId).get();
        if (m.exists) {
          final md = m.data() as Map<String, dynamic>;
          final fullField = (md['fullName'] ?? '').toString().trim();
          final fn = (md['firstName'] ?? '').toString().trim();
          final ln = (md['lastName'] ?? '').toString().trim();
          final full = fullField.isNotEmpty ? fullField : [fn, ln].where((s) => s.isNotEmpty).join(' ').trim();
          if (full.isNotEmpty) {
            _nameCache[requestedByUid] = full;
            return full;
          }
        }
      }
    } catch (_) {}
    final fb = (fallbackEmail ?? '').trim();
    if (fb.isNotEmpty) {
      _nameCache[requestedByUid] = fb;
      return fb;
    }
    _nameCache[requestedByUid] = requestedByUid;
    return requestedByUid;
  }

  Future<void> _enqueueAction({
    required String requestId,
    required String decision, // 'approve' | 'decline'
    String? reason,
  }) async {
    if (!_isPastor || _uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only pastors can approve or decline.')),
      );
      return;
    }

    try {
      await _db.collection('ministry_approval_actions').add({
        'requestId': requestId,
        'decision': decision,               // <-- matches Cloud Function
        'reviewerUid': _uid,                // <-- matches Cloud Function
        'reason': (reason ?? '').trim().isEmpty ? null : reason!.trim(),
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(decision == 'approve' ? 'Approval queued' : 'Decline queued')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error queuing action: $e')),
      );
    }
  }

  Future<void> _confirmDecline(String requestId) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Decline request'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Optional: add a reason for declining',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Decline')),
        ],
      ),
    );
    if (ok == true) {
      await _enqueueAction(requestId: requestId, decision: 'decline', reason: controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingRole) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_canView) {
      final pretty = const JsonEncoder.withIndent('  ').convert(_debug);
      return Scaffold(
        appBar: AppBar(title: const Text('Ministry Approvals')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Access denied.\nOnly pastors and admins can view ministry creation requests.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  if (kDebugMode) ...[
                    const Divider(),
                    Text('Debug info:', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SelectableText(pretty),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    final query = _db
        .collection('ministry_creation_requests')
        .where('status', isEqualTo: 'pending')
        .orderBy('requestedAt', descending: true);

    return Scaffold(
      appBar: AppBar(title: const Text('Ministry Approvals')),
      body: StreamBuilder<QuerySnapshot>(
        stream: query.snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final docs = snap.data!.docs;
          if (docs.isEmpty) return const Center(child: Text('No pending requests.'));

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final d = docs[i];
              final data = d.data() as Map<String, dynamic>;
              final id = d.id;

              final ministryName = (data['name'] ?? data['ministryName'] ?? '').toString();
              final description = (data['description'] ?? '').toString();
              final requestedByUid = (data['requestedByUid'] ?? '').toString();
              final requesterEmail = (data['requesterEmail'] ?? '').toString();
              final requesterFullName = (data['requesterFullName'] ?? '').toString();

              final ts = data['requestedAt'] ?? data['createdAt'];
              final requestedAt = ts is Timestamp ? ts.toDate() : null;

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(ministryName.isEmpty ? 'Unnamed Ministry' : ministryName,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 6),
                      if (description.isNotEmpty) Text(description),
                      const SizedBox(height: 6),
                      FutureBuilder<String>(
                        future: _resolveRequesterName(
                          requestedByUid: requestedByUid,
                          fallbackFullName: requesterFullName.isNotEmpty ? requesterFullName : null,
                          fallbackEmail: requesterEmail.isNotEmpty ? requesterEmail : null,
                        ),
                        builder: (context, nameSnap) {
                          final name = nameSnap.data ?? '—';
                          return Wrap(
                            spacing: 12,
                            runSpacing: 6,
                            children: [
                              _Chip('Requester', name),
                              if (requesterEmail.isNotEmpty) _Chip('Email', requesterEmail),
                              _Chip(
                                'Requested At',
                                requestedAt == null
                                    ? '—'
                                    : '${requestedAt.toLocal()}',
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Tooltip(
                            message: _isPastor ? 'Decline' : 'Only pastors can act',
                            child: TextButton.icon(
                              onPressed: _isPastor ? () => _confirmDecline(id) : null,
                              icon: const Icon(Icons.cancel),
                              label: const Text('Decline'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Tooltip(
                            message: _isPastor ? 'Approve' : 'Only pastors can act',
                            child: ElevatedButton.icon(
                              onPressed: _isPastor
                                  ? () => _enqueueAction(
                                requestId: id,
                                decision: 'approve',
                              )
                                  : null,
                              icon: const Icon(Icons.check_circle),
                              label: const Text('Approve'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String value;
  const _Chip(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text('$label: ${value.isEmpty ? '—' : value}'),
      visualDensity: VisualDensity.compact,
    );
  }
}
