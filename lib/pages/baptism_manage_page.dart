import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:church_management_app/widgets/notificationbell_widget.dart';

class BaptismManagePage extends StatefulWidget {
  const BaptismManagePage({super.key});

  @override
  State<BaptismManagePage> createState() => _BaptismManagePageState();
}

class _BaptismManagePageState extends State<BaptismManagePage> {
  String _statusFilter = 'all'; // all | pending | accepted | declined
  final Map<String, String> _memberNameCache = {};

  Stream<QuerySnapshot<Map<String, dynamic>>> _stream() {
    final col = FirebaseFirestore.instance.collection('baptismRequests');
    if (_statusFilter == 'all') {
      return col.orderBy('requestedAt', descending: true).snapshots();
    }
    // NOTE: This query may require a Firestore index:
    // baptismRequests where status == <value> order by requestedAt desc
    return col
        .where('status', isEqualTo: _statusFilter)
        .orderBy('requestedAt', descending: true)
        .snapshots();
  }

  Future<String> _memberName(String memberId, {String? fallback}) async {
    if (fallback != null && fallback.trim().isNotEmpty) {
      _memberNameCache[memberId] = fallback.trim();
      return fallback.trim();
    }
    if (_memberNameCache.containsKey(memberId)) {
      return _memberNameCache[memberId]!;
    }
    final m = await FirebaseFirestore.instance.collection('members').doc(memberId).get();
    final md = m.data() ?? {};
    final name = (md['fullName'] ??
        [md['firstName'], md['lastName']]
            .where((e) => (e ?? '').toString().trim().isNotEmpty)
            .join(' '))
        .toString()
        .trim();
    final safe = name.isEmpty ? 'Unnamed member' : name;
    _memberNameCache[memberId] = safe;
    return safe;
  }

  int? _ageFrom(Map<String, dynamic> data) {
    if (data['age'] is int) return data['age'] as int;
    if (data['birthDate'] is Timestamp) {
      final dt = (data['birthDate'] as Timestamp).toDate();
      final now = DateTime.now();
      var a = now.year - dt.year;
      if (DateTime(now.year, dt.month, dt.day).isAfter(now)) a--;
      return a;
    }
    return null;
  }

  String _cap(String s) => s.isEmpty ? s : (s[0].toUpperCase() + s.substring(1));

  Future<void> _decide(BuildContext context, String requestId, String decision, {String? reason}) async {
    try {
      final callable = FirebaseFunctions.instance.httpsCallable(
        'decideBaptismRequest',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 15)),
      );
      await callable.call(<String, dynamic>{
        'requestId': requestId,
        'decision': decision, // 'accepted' | 'declined'
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      });

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Decision saved: $decision')),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cloud Function failed: ${e.code} ${e.message ?? ''}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _confirmAccept(BuildContext context, String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Accept request'),
        content: const Text('Are you sure you want to accept this baptism request?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Accept')),
        ],
      ),
    );
    if (ok == true) _decide(context, id, 'accepted');
  }

  Future<void> _confirmDecline(BuildContext context, String id) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Decline request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Optional: Provide a reason to include in the notification.'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Decline')),
        ],
      ),
    );
    if (ok == true) _decide(context, id, 'declined', reason: controller.text);
  }

  Widget _filters() {
    Widget chip(String label, String value) {
      final selected = _statusFilter == value;
      return ChoiceChip(
        selected: selected,
        label: Text(label),
        onSelected: (_) => setState(() => _statusFilter = value),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          chip('All', 'all'),
          chip('Pending', 'pending'),
          chip('Accepted', 'accepted'),
          chip('Declined', 'declined'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Baptism Requests'),
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
          NotificationBell(),
        ],
      ),
      body: Column(
        children: [
          _filters(),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _stream(),
              builder: (context, snap) {
                if (snap.hasError) return Center(child: Text('Error: ${snap.error}'));
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Center(child: Text('No baptism requests'));
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final data = d.data();
                    final memberId = (data['memberId'] ?? '').toString();
                    final memberNameSnapshot = (data['memberName'] ?? '').toString();
                    final gender = (data['gender'] ?? '').toString();
                    final season = (data['season'] ?? '').toString(); // NEW
                    final notes = (data['notes'] ?? '').toString();
                    final status = (data['status'] ?? 'pending').toString();

                    final age = _ageFrom(data);

                    return FutureBuilder<String>(
                      future: _memberName(memberId, fallback: memberNameSnapshot),
                      builder: (context, nameSnap) {
                        final name = (nameSnap.data ?? memberNameSnapshot).trim();
                        return Card(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Top row: name + status chip
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        name.isEmpty ? 'Unnamed member' : name,
                                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                                      ),
                                    ),
                                    _StatusChip(status: status),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                // Details line: gender • age • season
                                Text(
                                  'Gender: ${gender.isEmpty ? "—" : gender}'
                                      '${age != null ? " • Age: $age" : ""}'
                                      '${season.isNotEmpty ? " • Season: ${_cap(season)}" : ""}',
                                  style: TextStyle(color: Colors.grey.shade700),
                                ),
                                if (notes.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    notes,
                                    maxLines: 6,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                                const SizedBox(height: 10),
                                if (status == 'pending')
                                  Row(
                                    children: [
                                      OutlinedButton.icon(
                                        icon: const Icon(Icons.close),
                                        label: const Text('Decline'),
                                        onPressed: () => _confirmDecline(context, d.id),
                                      ),
                                      const SizedBox(width: 8),
                                      ElevatedButton.icon(
                                        icon: const Icon(Icons.check),
                                        label: const Text('Accept'),
                                        onPressed: () => _confirmAccept(context, d.id),
                                      ),
                                    ],
                                  )
                                else
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Text(
                                      status == 'accepted' ? 'Accepted' : 'Declined',
                                      style: TextStyle(
                                        color: status == 'accepted' ? Colors.green : Colors.red,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    Color bg;
    IconData icon;
    String label;
    switch (status) {
      case 'accepted':
        bg = Colors.green.shade100;
        icon = Icons.check_circle;
        label = 'Accepted';
        break;
      case 'declined':
        bg = Colors.red.shade100;
        icon = Icons.cancel;
        label = 'Declined';
        break;
      default:
        bg = Colors.amber.shade100;
        icon = Icons.hourglass_bottom;
        label = 'Pending';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
