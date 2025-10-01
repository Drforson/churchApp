import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/join_request_model.dart';

class JoinRequestApprovalPage extends StatefulWidget {
  const JoinRequestApprovalPage({super.key});

  @override
  State<JoinRequestApprovalPage> createState() => _JoinRequestApprovalPageState();
}

class _JoinRequestApprovalPageState extends State<JoinRequestApprovalPage> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String? userId;
  String userRole = 'member';

  @override
  void initState() {
    super.initState();
    userId = _auth.currentUser?.uid;
    _fetchUserRole();
  }

  Future<void> _fetchUserRole() async {
    final userDoc = await _db.collection('users').doc(userId).get();
    setState(() {
      userRole = userDoc.data()?['role'] ?? 'member';
    });
  }

  Future<List<JoinRequestModel>> _fetchJoinRequests() async {
    final snapshot = await _db
        .collection('joinRequests')
        .where('status', isEqualTo: 'pending')
        .orderBy('timestamp', descending: true)
        .get();
    return snapshot.docs.map((doc) => JoinRequestModel.fromDocument(doc)).toList();
  }

  Future<void> _updateRequestStatus(String requestId, String newStatus) async {
    await _db.collection('joinRequests').doc(requestId).update({'status': newStatus});
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (userRole != 'admin' && userRole != 'leader') {
      return const Scaffold(
        body: Center(child: Text("Access denied. Only leaders and admins can view this page.")),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("Join Requests")),
      body: FutureBuilder<List<JoinRequestModel>>(
        future: _fetchJoinRequests(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final requests = snapshot.data!;
          if (requests.isEmpty) {
            return const Center(child: Text("No join requests found."));
          }

          return ListView.builder(
            itemCount: requests.length,
            itemBuilder: (context, index) {
              final request = requests[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: ListTile(
                  title: Text("Member: ${request.memberId}"),
                  subtitle: Text("Ministry: ${request.ministryId}\nStatus: ${request.status}"),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.check, color: Colors.green),
                        onPressed: () => _updateRequestStatus(request.id, 'approved'),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.red),
                        onPressed: () => _updateRequestStatus(request.id, 'rejected'),
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
