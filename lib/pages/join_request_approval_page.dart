import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import '../core/firestore_paths.dart';
import '../models/join_request_model.dart';

class JoinRequestApprovalPage extends StatefulWidget {
  const JoinRequestApprovalPage({super.key});

  @override
  State<JoinRequestApprovalPage> createState() =>
      _JoinRequestApprovalPageState();
}

class _JoinRequestApprovalPageState extends State<JoinRequestApprovalPage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');

  bool _loadingRole = true;
  bool _isAdminOrLeader = false;

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  Future<void> _loadRole() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      setState(() {
        _loadingRole = false;
        _isAdminOrLeader = false;
      });
      return;
    }
    final token = await _auth.currentUser!.getIdTokenResult(true);
    final claims = token.claims ?? const <String, dynamic>{};

    final userSnap = await _db.collection(FP.users).doc(uid).get();
    final user = userSnap.data() ?? const <String, dynamic>{};
    final roles = (user['roles'] is List)
        ? List<String>.from(
            (user['roles'] as List).map((e) => e.toString().toLowerCase()),
          )
        : <String>[];
    final roleSingle = (user['role'] ?? '').toString().toLowerCase().trim();
    final hasLeadMins = (user['leadershipMinistries'] is List) &&
        (user['leadershipMinistries'] as List).isNotEmpty;

    bool isAdmin = roles.contains('admin') ||
        roleSingle == 'admin' ||
        user['admin'] == true ||
        user['isAdmin'] == true ||
        claims['admin'] == true ||
        claims['isAdmin'] == true;
    bool isLeader = roles.contains('leader') ||
        roleSingle == 'leader' ||
        user['leader'] == true ||
        user['isLeader'] == true ||
        hasLeadMins ||
        claims['leader'] == true ||
        claims['isLeader'] == true;

    final memberId = (user['memberId'] ?? '').toString();
    if (memberId.isNotEmpty) {
      final memberSnap = await _db.collection('members').doc(memberId).get();
      final member = memberSnap.data() ?? const <String, dynamic>{};
      final memberRoles = (member['roles'] is List)
          ? List<String>.from(
              (member['roles'] as List).map((e) => e.toString().toLowerCase()),
            )
          : const <String>[];
      final memberLeads = (member['leadershipMinistries'] is List)
          ? List<String>.from(member['leadershipMinistries'] as List)
          : const <String>[];
      isAdmin = isAdmin || memberRoles.contains('admin');
      isLeader =
          isLeader || memberRoles.contains('leader') || memberLeads.isNotEmpty;
    }

    setState(() {
      _loadingRole = false;
      _isAdminOrLeader = isAdmin || isLeader;
    });
  }

  Future<void> _updateStatus(String requestId, String newStatus) async {
    final action = newStatus == 'approved' ? 'approve' : 'reject';
    await _functions.httpsCallable('leaderModerateJoinRequest').call({
      'requestId': requestId,
      'action': action,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingRole) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_isAdminOrLeader) {
      return const Scaffold(
        body: Center(
            child: Text(
                'Access denied. Only leaders and admins can view this page.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Join Requests')),
      body: StreamBuilder<QuerySnapshot>(
        stream: _db
            .collection(FP.joinRequests)
            .where('status', isEqualTo: 'pending')
            .orderBy('requestedAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('No join requests found.'));
          }

          final requests =
              docs.map((d) => JoinRequestModel.fromDocument(d)).toList();

          return ListView.builder(
            itemCount: requests.length,
            itemBuilder: (context, i) {
              final r = requests[i];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: ListTile(
                  title: Text('Member: ${r.memberId}'),
                  subtitle:
                      Text('Ministry: ${r.ministryId}\nStatus: ${r.status}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Approve',
                        icon:
                            const Icon(Icons.check_circle, color: Colors.green),
                        onPressed: () => _updateStatus(r.id, 'approved'),
                      ),
                      IconButton(
                        tooltip: 'Reject',
                        icon: const Icon(Icons.cancel, color: Colors.red),
                        onPressed: () => _updateStatus(r.id, 'rejected'),
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
