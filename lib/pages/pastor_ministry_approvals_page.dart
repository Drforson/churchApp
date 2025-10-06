import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class PastorMinistryApprovalsPage extends StatelessWidget {
  const PastorMinistryApprovalsPage({super.key});

  Future<void> _approveRequest(BuildContext context, DocumentSnapshot doc) async {
    final data = doc.data() as Map<String, dynamic>;
    final String name = (data['name'] ?? '').toString();
    final String description = (data['description'] ?? '').toString();
    final String requesterUid = (data['requestedByUid'] ?? '').toString();

    final db = FirebaseFirestore.instance;
    final batch = db.batch();

    // Create ministry doc (id can be auto or slug; we use auto for simplicity)
    final newMinRef = db.collection('ministries').doc();
    batch.set(newMinRef, {
      'name': name,
      'description': description,
      'leaderIds': requesterUid.isNotEmpty ? [requesterUid] : <String>[],
      'createdBy': requesterUid,
      'approved': true,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // Mark request approved
    batch.update(doc.reference, {
      'status': 'approved',
      'updatedAt': FieldValue.serverTimestamp(),
      'approvedMinistryId': newMinRef.id,
    });

    // Notification to requester
    batch.set(db.collection('notifications').doc(), {
      'type': 'ministry_request_result',
      'title': 'Ministry approved',
      'body': '$name has been approved.',
      'createdAt': FieldValue.serverTimestamp(),
      'read': false,
      'toUid': requesterUid,
    });

    await batch.commit();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approved "$name"')),
      );
    }
  }

  Future<void> _declineRequest(BuildContext context, DocumentSnapshot doc) async {
    final data = doc.data() as Map<String, dynamic>;
    final String name = (data['name'] ?? '').toString();
    final String requesterUid = (data['requestedByUid'] ?? '').toString();

    final db = FirebaseFirestore.instance;
    final batch = db.batch();

    batch.update(doc.reference, {
      'status': 'declined',
      'updatedAt': FieldValue.serverTimestamp(),
    });

    batch.set(db.collection('notifications').doc(), {
      'type': 'ministry_request_result',
      'title': 'Ministry declined',
      'body': '$name was declined.',
      'createdAt': FieldValue.serverTimestamp(),
      'read': false,
      'toUid': requesterUid,
    });

    await batch.commit();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Declined "$name"')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = FirebaseFirestore.instance
        .collection('ministry_creation_requests')
        .where('status', isEqualTo: 'pending')
        .orderBy('requestedAt', descending: true);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ministry Approvals'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const Center(child: Text('No pending requests.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final d = docs[i];
              final data = d.data() as Map<String, dynamic>;
              final name = (data['name'] ?? '').toString();
              final desc = (data['description'] ?? '').toString();
              final email = (data['requesterEmail'] ?? '').toString();

              return Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 2,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    [
                      if (email.isNotEmpty) 'Requested by: $email',
                      if (desc.isNotEmpty) 'Description: $desc',
                    ].where((s) => s.isNotEmpty).join('\n'),
                  ),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Decline'),
                        onPressed: () => _declineRequest(context, d),
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Approve'),
                        onPressed: () => _approveRequest(context, d),
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
