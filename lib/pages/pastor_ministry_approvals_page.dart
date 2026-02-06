// lib/pages/pastor_ministry_approvals_page.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Shows pending ministry creation requests to pastors/admins.
/// Approve/Decline creates a doc in `ministry_approval_actions`:
/// { decision: 'approve'|'decline', requestId, reviewerUid, reason? }
class PastorMinistryApprovalsPage extends StatefulWidget {
  const PastorMinistryApprovalsPage({super.key, this.requestId});

  final String? requestId;

  @override
  State<PastorMinistryApprovalsPage> createState() =>
      _PastorMinistryApprovalsPageState();
}

class _PastorMinistryApprovalsPageState
    extends State<PastorMinistryApprovalsPage> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? _uid;
  bool _submitting = false; // guards double taps
  String? _focusRequestId;
  bool _autoOpened = false;

  @override
  void initState() {
    super.initState();
    _uid = _auth.currentUser?.uid;
    _focusRequestId = widget.requestId?.trim().isEmpty == false
        ? widget.requestId!.trim()
        : null;
  }

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _pendingRequests() {
    return _db
        .collection('ministry_creation_requests')
        .where('status', isEqualTo: 'pending')
        .orderBy('requestedAt', descending: true)
        .snapshots()
        .map((s) => s.docs);
  }

  Future<void> _submitAction({
    required String requestId,
    required String decision, // 'approve' | 'decline'
    String? reason,
  }) async {
    if (_uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You must be signed in to perform this action.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (_submitting) return;

    setState(() => _submitting = true);
    try {
      await _db.collection('ministry_approval_actions').add({
        'requestId': requestId,
        'decision': decision,
        'reason': (reason ?? '').trim().isEmpty ? null : reason!.trim(),
        'reviewerUid': _uid,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            decision == 'approve'
                ? 'Approval submitted. Creating ministry…'
                : 'Decline submitted.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not submit: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _confirmApprove(
      String requestId,
      String name,
      ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Approve request'),
        content: Text(
          'Approve creation of “$name”? This will:\n'
              '• create the ministry document\n'
              '• add the requester as a leader and member\n'
              '• notify the requester',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.check),
            label: const Text('Approve'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _submitAction(requestId: requestId, decision: 'approve');
    }
  }

  Future<void> _confirmDecline(String requestId, String name) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Decline request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Decline the request for “$name”?'),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'Add a short reason the requester will see',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.block),
            label: const Text('Decline'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _submitAction(
        requestId: requestId,
        decision: 'decline',
        reason: reasonCtrl.text,
      );
    }
  }

  void _openDetails(Map<String, dynamic> r) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        final requestedAt = (r['requestedAt'] as Timestamp?)?.toDate();
        final when = requestedAt != null
            ? DateFormat('EEE, dd MMM yyyy • HH:mm').format(requestedAt)
            : '—';
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Text(
                r['name']?.toString() ?? 'Untitled ministry',
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text('Requested: $when'),
              const SizedBox(height: 12),
              if ((r['description'] ?? '').toString().trim().isNotEmpty) ...[
                Text(
                  r['description'].toString(),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
              ],
              const Divider(),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(
                    (r['requesterFullName'] ?? r['requesterEmail'] ?? 'Requester')
                        .toString()),
                subtitle: Text('UID: ${(r['requestedByUid'] ?? '—').toString()}'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => _confirmDecline(
                        r['id'].toString(),
                        r['name']?.toString() ?? 'this ministry',
                      ),
                      icon: const Icon(Icons.block),
                      label: const Text('Decline'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _submitting
                          ? null
                          : () => _confirmApprove(
                        r['id'].toString(),
                        r['name']?.toString() ?? 'this ministry',
                      ),
                      icon: const Icon(Icons.check),
                      label: const Text('Approve'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasFocus = _focusRequestId != null && _focusRequestId!.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ministry Approvals'),
        actions: [
          if (hasFocus)
            TextButton(
              onPressed: () => setState(() {
                _focusRequestId = null;
                _autoOpened = false;
              }),
              child: const Text('Show all'),
            ),
        ],
      ),
      body: StreamBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
        stream: _pendingRequests(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data ?? const [];
          final viewDocs = hasFocus
              ? docs.where((d) => d.id == _focusRequestId).toList()
              : docs;

          if (viewDocs.isEmpty) {
            return const Center(
              child: Text('No pending ministry requests.'),
            );
          }

          if (hasFocus && !_autoOpened) {
            final match = viewDocs.first;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _autoOpened = true);
              final r = match.data();
              r['id'] = match.id;
              _openDetails(r);
            });
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: viewDocs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final d = viewDocs[i];
              final r = d.data();
              r['id'] = d.id; // convenience

              final title = (r['name'] ?? 'Untitled ministry').toString();
              final desc = (r['description'] ?? '').toString();
              final requestedAt = (r['requestedAt'] as Timestamp?)?.toDate();
              final when = requestedAt != null
                  ? DateFormat('dd MMM yyyy • HH:mm').format(requestedAt)
                  : '—';

              return Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListTile(
                  contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  leading: const CircleAvatar(
                    child: Icon(Icons.church),
                  ),
                  title: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    [
                      if (desc.trim().isNotEmpty) desc.trim(),
                      'Requested: $when',
                    ].join('\n'),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  onTap: () => _openDetails(r),
                  trailing: Wrap(
                    spacing: 6,
                    children: [
                      IconButton(
                        tooltip: 'Decline',
                        onPressed: _submitting
                            ? null
                            : () => _confirmDecline(d.id, title),
                        icon: const Icon(Icons.block),
                      ),
                      IconButton(
                        tooltip: 'Approve',
                        onPressed: _submitting
                            ? null
                            : () => _confirmApprove(d.id, title),
                        icon: const Icon(Icons.check_circle_outline),
                        color: Colors.green,
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
