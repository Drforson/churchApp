import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class PastorMinistryApprovalsPage extends StatefulWidget {
  const PastorMinistryApprovalsPage({super.key});

  @override
  State<PastorMinistryApprovalsPage> createState() => _PastorMinistryApprovalsPageState();
}

class _PastorMinistryApprovalsPageState extends State<PastorMinistryApprovalsPage> {
  final _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');
  final Set<String> _busy = {};

  Future<void> _approveRequest(BuildContext context, String requestId, String name) async {
    setState(() => _busy.add(requestId));
    try {
      await _functions.httpsCallable('approveMinistryCreation').call({'requestId': requestId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Approved "$name"')));
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Failed to approve (permission?).')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(requestId));
    }
  }

  Future<void> _declineRequest(BuildContext context, String requestId, String name) async {
    final reason = await _askReason(context);
    if (reason == null) return;

    setState(() => _busy.add(requestId));
    try {
      await _functions.httpsCallable('declineMinistryCreation').call({
        'requestId': requestId,
        'reason': reason.trim().isEmpty ? null : reason.trim(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Declined "$name"')));
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        final msg = e.code == 'permission-denied'
            ? 'Permission denied. Make sure your user has the Pastor or Admin role.'
            : (e.message ?? 'Failed to decline.');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(requestId));
    }
  }

  Future<String?> _askReason(BuildContext context) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Decline request'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Reason (optional)',
            hintText: 'Optionally provide a reason',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Decline')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final q = FirebaseFirestore.instance
        .collection('ministry_creation_requests')
        .where('status', isEqualTo: 'pending'); // sort client-side

    return Scaffold(
      appBar: AppBar(title: const Text('Ministry Approvals')),
      body: StreamBuilder<QuerySnapshot>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error loading requests:\n${snap.error}', textAlign: TextAlign.center),
              ),
            );
          }
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = [...(snap.data?.docs ?? const <QueryDocumentSnapshot>[])];

          // Sort by requestedAt desc (handles nulls)
          docs.sort((a, b) {
            final ad = (a.data() as Map<String, dynamic>)['requestedAt'];
            final bd = (b.data() as Map<String, dynamic>)['requestedAt'];
            final aMs = ad is Timestamp ? ad.millisecondsSinceEpoch : 0;
            final bMs = bd is Timestamp ? bd.millisecondsSinceEpoch : 0;
            return bMs.compareTo(aMs);
          });

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
              final id = d.id;
              final name = (data['name'] ?? '').toString();
              final desc = (data['description'] ?? '').toString();
              final email = (data['requesterEmail'] ?? '').toString();
              final busy = _busy.contains(id);

              return Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 2,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text([
                    if (email.isNotEmpty) 'Requested by: $email',
                    if (desc.isNotEmpty) 'Description: $desc',
                  ].where((e) => e.isNotEmpty).join('\n')),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.close, size: 18),
                        label: busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Decline'),
                        onPressed: busy ? null : () => _declineRequest(context, id, name),
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.check, size: 18),
                        label: busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Approve'),
                        onPressed: busy ? null : () => _approveRequest(context, id, name),
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
