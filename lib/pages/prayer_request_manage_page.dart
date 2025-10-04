import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class PrayerRequestManagePage extends StatelessWidget {
  const PrayerRequestManagePage({super.key});

  Stream<QuerySnapshot<Map<String, dynamic>>> _stream() {
    // Expect collection: prayerRequests with fields:
    // { memberId, message, createdAt(Timestamp), status: 'open'|'prayed' }
    return FirebaseFirestore.instance
        .collection('prayerRequests')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Future<void> _markPrayed(BuildContext context, String requestId) async {
    try {
      // Optional: call CF to notify member; here client write then CF trigger (or callable) is fine.
      await FirebaseFirestore.instance.collection('prayerRequests').doc(requestId).update({
        'status': 'prayed',
        'prayedAt': FieldValue.serverTimestamp(),
        'pastorId': FirebaseAuth.instance.currentUser?.uid,
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Marked as prayed')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<Widget> _memberName(String? memberId) async {
    if (memberId == null) return const Text('Unknown member');
    final m = await FirebaseFirestore.instance.collection('members').doc(memberId).get();
    final md = m.data() ?? {};
    final name = (md['fullName'] ??
        [md['firstName'], md['lastName']]
            .where((e) => (e ?? '').toString().trim().isNotEmpty)
            .join(' '))
        .toString();
    return Text(name.isEmpty ? 'Unnamed member' : name, style: const TextStyle(fontWeight: FontWeight.w600));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prayer Requests'),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.pushNamedAndRemoveUntil(context, '/login', (r) => false);
              }
            },
          ),
          // Your NotificationBell widget
          // ignore: use_build_context_synchronously
          // Add: import 'package:church_management_app/widgets/notificationbell_widget.dart';
          // NotificationBell(),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _stream(),
        builder: (context, snap) {
          if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());

          final docs = snap.data!.docs;
          if (docs.isEmpty) return const Center(child: Text('No prayer requests'));

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 0),
            itemBuilder: (context, i) {
              final d = docs[i];
              final data = d.data();
              final status = (data['status'] ?? 'open').toString();
              final memberId = data['memberId'] as String?;
              final message = (data['message'] ?? '').toString();

              return FutureBuilder<Widget>(
                future: _memberName(memberId),
                builder: (context, nameSnap) {
                  final nameWidget = nameSnap.data ?? const Text('...');
                  return ListTile(
                    title: nameWidget,
                    subtitle: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
                    trailing: status == 'prayed'
                        ? const Chip(label: Text('Prayed'), avatar: Icon(Icons.check))
                        : ElevatedButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Mark prayed'),
                      onPressed: () => _markPrayed(context, d.id),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
