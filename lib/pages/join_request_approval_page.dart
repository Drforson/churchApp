import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../core/firestore_paths.dart';
import '../models/join_request_model.dart';

class JoinRequestApprovalPage extends StatefulWidget {
  const JoinRequestApprovalPage({super.key});

  @override
  State<JoinRequestApprovalPage> createState() => _JoinRequestApprovalPageState();
}

class _JoinRequestApprovalPageState extends State<JoinRequestApprovalPage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

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
    final snap = await _db.collection(FP.users).doc(uid).get();
    final roles = (snap.data()?['roles'] is List)
        ? List<String>.from(snap.data()!['roles'])
        : <String>[];
    setState(() {
      _loadingRole = false;
      _isAdminOrLeader = roles.contains('admin') || roles.contains('leader');
    });
  }

  Future<void> _updateStatus(String requestId, String newStatus) async {
    // Allowed by rules for leaders/admins only.
    await _db.collection(FP.joinRequests).doc(requestId).update({
      'status': newStatus,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingRole) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_isAdminOrLeader) {
      return const Scaffold(
        body: Center(child: Text('Access denied. Only leaders and admins can view this page.')),
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

          final requests = docs
              .map((d) => JoinRequestModel.fromDocument(d))
              .toList();

          return ListView.builder(
            itemCount: requests.length,
            itemBuilder: (context, i) {
              final r = requests[i];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: ListTile(
                  title: Text('Member: ${r.memberId}'),
                  subtitle: Text('Ministry: ${r.ministryId}\nStatus: ${r.status}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Approve',
                        icon: const Icon(Icons.check_circle, color: Colors.green),
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
