import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';

class PastorMinistryApprovalsPage extends StatefulWidget {
  const PastorMinistryApprovalsPage({super.key});

  @override
  State<PastorMinistryApprovalsPage> createState() => _PastorMinistryApprovalsPageState();
}

class _PastorMinistryApprovalsPageState extends State<PastorMinistryApprovalsPage> {
  final _db = FirebaseFirestore.instance;

  final Set<String> _busy = {};
  final Map<String, String> _nameCache = {};

  /* =========================
     Enqueue Approve / Decline
     ========================= */
  Future<void> _approveRequest(BuildContext context, String requestId, String name) async {
    setState(() => _busy.add(requestId));
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await _db.collection('ministry_approval_actions').add({
        'action': 'approve',
        'requestId': requestId,
        'byUid': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Approval submitted for "$name"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to approve: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(requestId));
    }
  }

  Future<void> _declineRequest(BuildContext context, String requestId, String name) async {
    final reason = await _showDeclineDialogAndReturnReason(context);
    if (reason == null) return;

    setState(() => _busy.add(requestId));
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await _db.collection('ministry_approval_actions').add({
        'action': 'decline',
        'requestId': requestId,
        'reason': reason.trim().isEmpty ? null : reason.trim(),
        'byUid': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Decline submitted for "$name"')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to decline: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(requestId));
    }
  }

  /* =========================
     Requester Name lookup
     ========================= */
  Future<String> _resolveRequesterName(Map<String, dynamic> data) async {
    final memberId = (data['requestedByMemberId'] ?? '').toString();
    final uid = (data['requestedByUid'] ?? '').toString();
    final email = (data['requesterEmail'] ?? '').toString();

    if (memberId.isNotEmpty) {
      final key = 'mem:$memberId';
      final cached = _nameCache[key];
      if (cached != null) return cached;
      try {
        final mem = await _db.collection('members').doc(memberId).get();
        if (mem.exists) {
          final m = mem.data() ?? {};
          final full = (m['fullName'] ?? '').toString().trim();
          final first = (m['firstName'] ?? '').toString().trim();
          final last = (m['lastName'] ?? '').toString().trim();
          final name = full.isNotEmpty ? full : [first, last].where((e) => e.isNotEmpty).join(' ').trim();
          if (name.isNotEmpty) {
            _nameCache[key] = name;
            return name;
          }
        }
      } catch (_) {}
    }

    if (uid.isNotEmpty) {
      final key = 'uid:$uid';
      final cached = _nameCache[key];
      if (cached != null) return cached;
      try {
        final usr = await _db.collection('users').doc(uid).get();
        if (usr.exists) {
          final u = usr.data() ?? {};
          final full = (u['fullName'] ?? '').toString().trim();
          if (full.isNotEmpty) {
            _nameCache[key] = full;
            return full;
          }
          final linkedMemberId = (u['memberId'] ?? '').toString();
          if (linkedMemberId.isNotEmpty) {
            final name = await _resolveRequesterName({'requestedByMemberId': linkedMemberId});
            _nameCache[key] = name;
            return name;
          }
        }
      } catch (_) {}
    }

    if (email.isNotEmpty) return email.split('@').first;
    return 'Requester';
  }

  Widget _RequesterNamePill(Map<String, dynamic> data) {
    return FutureBuilder<String>(
      future: _resolveRequesterName(data),
      builder: (context, snap) {
        final text = snap.data ?? 'Requester';
        return _InfoTag(icon: Icons.person, text: 'Requested by: $text', maxTextWidth: 280);
      },
    );
  }

  /* =========================
     Decline dialog (safe submit)
     ========================= */
  Future<String?> _showDeclineDialogAndReturnReason(BuildContext context) async {
    final ctrl = TextEditingController();
    bool submitting = false;

    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setS) => AlertDialog(
            title: const Text('Decline request'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'Optionally provide a reason',
              ),
            ),
            actions: [
              TextButton(
                onPressed: submitting ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: submitting
                    ? null
                    : () async {
                  setS(() => submitting = true);
                  FocusScope.of(ctx).unfocus();
                  await Future.delayed(const Duration(milliseconds: 50));
                  Navigator.pop(ctx, ctrl.text.trim());
                },
                child: submitting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Decline'),
              ),
            ],
          ),
        );
      },
    );
  }

  /* =========================
     UI
     ========================= */
  @override
  Widget build(BuildContext context) {
    final q = _db.collection('ministry_creation_requests').where('status', isEqualTo: 'pending');

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

          return RefreshIndicator(
            onRefresh: () async {},
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
                final requestedAt = data['requestedAt'];
                final busy = _busy.contains(id);

                String when = '';
                if (requestedAt is Timestamp) {
                  final dt = requestedAt.toDate();
                  when = DateFormat('MMM d, yyyy • HH:mm').format(dt);
                }

                return Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header (wrap-safe)
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 520),
                              child: Text(
                                name.isEmpty ? '(Unnamed ministry)' : name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                              ),
                            ),
                            if (when.isNotEmpty) _InfoTag(icon: Icons.schedule, text: when),
                          ],
                        ),

                        const SizedBox(height: 8),

                        // Meta info: requester NAME + (press-hold) description
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            _RequesterNamePill(data),
                            if (desc.isNotEmpty)
                              _PressHoldDescriptionPill(
                                text: desc,
                                collapsedLines: 1,
                                collapsedMaxWidth: 420,
                                expandedMaxWidth: 700,
                              ),
                          ],
                        ),

                        const SizedBox(height: 10),

                        // Actions
                        Row(
                          children: [
                            const Spacer(),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                OutlinedButton.icon(
                                  icon: busy
                                      ? const SizedBox(
                                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                      : const Icon(Icons.close, size: 18),
                                  label: busy ? const SizedBox.shrink() : const Text('Decline'),
                                  onPressed: busy ? null : () => _declineRequest(context, id, name),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                    minimumSize: const Size(0, 36),
                                  ),
                                ),
                                ElevatedButton.icon(
                                  icon: busy
                                      ? const SizedBox(
                                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                      : const Icon(Icons.check, size: 18),
                                  label: busy ? const SizedBox.shrink() : const Text('Approve'),
                                  onPressed: busy ? null : () => _approveRequest(context, id, name),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    minimumSize: const Size(0, 36),
                                  ),
                                ),
                              ],
                            ),
                          ],
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

/* ===========================
   Small UI helpers
   =========================== */

class _InfoTag extends StatelessWidget {
  final IconData icon;
  final String text;
  final int maxLines;
  final double? maxTextWidth;

  const _InfoTag({
    required this.icon,
    required this.text,
    this.maxLines = 1,
    this.maxTextWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.grey.shade700),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxTextWidth ?? 260),
            child: Text(
              text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade800, height: 1.25),
            ),
          ),
        ],
      ),
    );
  }
}

/// Press-and-hold to expand the description; release to collapse.
class _PressHoldDescriptionPill extends StatefulWidget {
  final String text;
  final int collapsedLines;
  final double collapsedMaxWidth;
  final double expandedMaxWidth;

  const _PressHoldDescriptionPill({
    required this.text,
    this.collapsedLines = 5,
    this.collapsedMaxWidth = 420,
    this.expandedMaxWidth = 700,
  });

  @override
  State<_PressHoldDescriptionPill> createState() => _PressHoldDescriptionPillState();
}

class _PressHoldDescriptionPillState extends State<_PressHoldDescriptionPill> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (mounted && _pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final bg = _pressed ? Colors.amber.shade50 : Colors.grey.shade100;
    final border = _pressed ? Colors.amber.shade200 : Colors.grey.shade300;

    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notes, size: 14, color: Colors.grey.shade700),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: _pressed ? widget.expandedMaxWidth : widget.collapsedMaxWidth,
            ),
            child: Text(
              widget.text,
              maxLines: _pressed ? 12 : widget.collapsedLines,
              overflow: _pressed ? TextOverflow.visible : TextOverflow.ellipsis,
              softWrap: true,
              style: TextStyle(
                fontSize: 12.5,
                color: Colors.grey.shade800,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      onLongPressStart: (_) => _setPressed(true),
      onLongPressEnd: (_) => _setPressed(false),
      child: content,
    );
  }
}
