import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class PastorMinistryApprovalsPage extends StatefulWidget {
  const PastorMinistryApprovalsPage({super.key});

  @override
  State<PastorMinistryApprovalsPage> createState() => _PastorMinistryApprovalsPageState();
}

class _PastorMinistryApprovalsPageState extends State<PastorMinistryApprovalsPage> {
  // === NEW: Guarded callable usage with fallback ===
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(region: 'europe-west2');
  bool _approveCallableOk = true;
  bool _declineCallableOk = true;

  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    // Lazy probe (no network call needed here; actual errors are caught at call time)
    // If you want an eager probe, you can try a lightweight ping callable.
  }

  // --- Approve helpers ---
  Future<void> _approveRequest(BuildContext context, String requestId, String name) async {
    setState(() => _busy.add(requestId));
    try {
      if (_approveCallableOk) {
        try {
          await _functions.httpsCallable('approveMinistryCreation').call({'requestId': requestId});
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Approved "$name"')));
          }
          // Best-effort pastor/requester notification (in case backend didn’t already)
          await _notifyOnApprove(requestId, name);
          return;
        } on FirebaseFunctionsException catch (e) {
          // Mark callable unreliable for this session; fallback to Firestore.
          _approveCallableOk = false;
          if (e.code == 'permission-denied') {
            // If pastor role/claims missing, fallback will likely be blocked by rules too.
            // Still attempt, and surface proper errors to user.
          }
        } catch (_) {
          _approveCallableOk = false;
        }
      }

      // === Fallback path ===
      await _approveViaFirestoreFallback(requestId, name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Approved "$name"')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to approve: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(requestId));
    }
  }

  // --- Decline helpers ---
  Future<void> _declineRequest(BuildContext context, String requestId, String name) async {
    final reason = await _askReason(context);
    if (reason == null) return;

    setState(() => _busy.add(requestId));
    try {
      if (_declineCallableOk) {
        try {
          await _functions.httpsCallable('declineMinistryCreation').call({
            'requestId': requestId,
            'reason': reason.trim().isEmpty ? null : reason.trim(),
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Declined "$name"')));
          }
          await _notifyOnDecline(requestId, name, reason);
          return;
        } on FirebaseFunctionsException catch (e) {
          _declineCallableOk = false;
          // permission-denied or app-check failures will fall through to Firestore fallback
        } catch (_) {
          _declineCallableOk = false;
        }
      }

      // === Fallback path ===
      await _declineViaFirestoreFallback(requestId, name, reason);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Declined "$name"')));
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().contains('PERMISSION_DENIED')
            ? 'Permission denied. Ensure this account has Pastor/Admin privileges.'
            : 'Failed to decline: $e';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(requestId));
    }
  }

  // === NEW: Fallback implementations ===

  /// Approve via client (when callable not available):
  /// - Creates a ministry doc (approved = true)
  /// - Marks request as approved with updatedAt
  /// - Creates best-effort notifications
  Future<void> _approveViaFirestoreFallback(String requestId, String requestName) async {
    final db = FirebaseFirestore.instance;

    await db.runTransaction((txn) async {
      final reqRef = db.collection('ministry_creation_requests').doc(requestId);
      final reqSnap = await txn.get(reqRef);
      if (!reqSnap.exists) {
        throw Exception('Request not found.');
      }
      final data = reqSnap.data() as Map<String, dynamic>;
      final status = (data['status'] ?? 'pending').toString();
      if (status != 'pending') {
        throw Exception('Request is not pending.');
      }

      final name = (data['name'] ?? requestName).toString().trim();
      final desc = (data['description'] ?? '').toString();
      final requestedByUid = (data['requestedByUid'] ?? '').toString();

      // Create/Upsert ministry. You can also enforce a unique slug if you need.
      final newMinRef = db.collection('ministries').doc(); // or .doc(slug)
      txn.set(newMinRef, {
        'id': newMinRef.id,
        'name': name,
        'description': desc,
        'approved': true,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': requestedByUid,
        // Optionally make requester a leader of the ministry:
        'leaderIds': requestedByUid.isNotEmpty ? [requestedByUid] : <String>[],
      }, SetOptions(merge: false));

      // Mark request approved
      txn.update(reqRef, {
        'status': 'approved',
        'approvedMinistryId': newMinRef.id,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    await _notifyOnApprove(requestId, requestName);
  }

  /// Decline via client fallback:
  /// - Updates status to declined and stores reason
  /// - Creates best-effort notifications
  Future<void> _declineViaFirestoreFallback(String requestId, String requestName, String? reason) async {
    final db = FirebaseFirestore.instance;

    await db.runTransaction((txn) async {
      final reqRef = db.collection('ministry_creation_requests').doc(requestId);
      final reqSnap = await txn.get(reqRef);
      if (!reqSnap.exists) {
        throw Exception('Request not found.');
      }
      final data = reqSnap.data() as Map<String, dynamic>;
      final status = (data['status'] ?? 'pending').toString();
      if (status != 'pending') {
        throw Exception('Request is not pending.');
      }

      txn.update(reqRef, {
        'status': 'declined',
        'declineReason': (reason ?? '').trim().isEmpty ? null : reason!.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });

    await _notifyOnDecline(requestId, requestName, reason);
  }

  // === NEW: Notifications on both paths (idempotent-enough) ===
  Future<void> _notifyOnApprove(String requestId, String name) async {
    final db = FirebaseFirestore.instance;
    await db.collection('notifications').add({
      'type': 'ministry_request_approved',
      'title': 'Ministry approved',
      'body': '"$name" has been approved',
      'toRole': 'pastor', // bell can filter
      'createdAt': FieldValue.serverTimestamp(),
      'requestId': requestId,
      'read': false,
    });
    // Notify requester too (best-effort)
    await db.collection('notifications').add({
      'type': 'ministry_request_approved',
      'title': 'Your ministry was approved',
      'body': '"$name" is now live.',
      'toRequester': true,
      'requestId': requestId,
      'createdAt': FieldValue.serverTimestamp(),
      'read': false,
    });
  }

  Future<void> _notifyOnDecline(String requestId, String name, String? reason) async {
    final db = FirebaseFirestore.instance;
    await db.collection('notifications').add({
      'type': 'ministry_request_declined',
      'title': 'Ministry declined',
      'body': '"$name" was declined${(reason ?? '').trim().isEmpty ? '' : ': $reason'}',
      'toRole': 'pastor',
      'createdAt': FieldValue.serverTimestamp(),
      'requestId': requestId,
      'read': false,
    });
    await db.collection('notifications').add({
      'type': 'ministry_request_declined',
      'title': 'Your ministry was declined',
      'body': '"$name" was declined${(reason ?? '').trim().isEmpty ? '' : ': $reason'}',
      'toRequester': true,
      'requestId': requestId,
      'createdAt': FieldValue.serverTimestamp(),
      'read': false,
    });
  }

  // === UI ===

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
        .where('status', isEqualTo: 'pending'); // stream & sort client-side

    return Scaffold(
      appBar: AppBar(title: const Text('Ministry Approvals')),
      body: StreamBuilder<QuerySnapshot>(
        stream: q.snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Error loading requests:\n${snap.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = [...(snap.data?.docs ?? const <QueryDocumentSnapshot>[])]
            ..sort((a, b) {
              final ad = (a.data() as Map<String, dynamic>)['requestedAt'];
              final bd = (b.data() as Map<String, dynamic>)['requestedAt'];
              final aMs = ad is Timestamp ? ad.millisecondsSinceEpoch : 0;
              final bMs = bd is Timestamp ? bd.millisecondsSinceEpoch : 0;
              return bMs.compareTo(aMs);
            });

          if (docs.isEmpty) {
            return const Center(child: Text('No pending requests.'));
          }

          return RefreshIndicator(
            onRefresh: () async {}, // the stream auto-refreshes; pull just shows UI affordance
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
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
                final requestedAt = data['requestedAt'];
                final busy = _busy.contains(id);

                String when = '';
                if (requestedAt is Timestamp) {
                  final dt = requestedAt.toDate();
                  when = '${dt.toLocal()}';
                }

                return Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(16),
                    title: Text(
                      name.isEmpty ? '(Unnamed ministry)' : name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text([
                      if (email.isNotEmpty) 'Requested by: $email',
                      if (when.isNotEmpty) 'Requested at: $when',
                      if (desc.isNotEmpty) 'Description: $desc',
                    ].where((e) => e.isNotEmpty).join('\n')),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.close, size: 18),
                          label: busy ? const SizedBox.shrink() : const Text('Decline'),
                          onPressed: busy ? null : () => _declineRequest(context, id, name),
                        ),
                        ElevatedButton.icon(
                          icon: busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.check, size: 18),
                          label: busy ? const SizedBox.shrink() : const Text('Approve'),
                          onPressed: busy ? null : () => _approveRequest(context, id, name),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
