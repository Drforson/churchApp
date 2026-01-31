import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class EventsPage extends StatefulWidget {
  const EventsPage({super.key});

  @override
  State<EventsPage> createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseFirestore.instance;

  // UI state
  String _search = '';
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  String _scope = 'Upcoming'; // Upcoming | Past
  String _visibility = 'All'; // All | Church-wide | My ministries

  // Role state
  bool _isAdmin = false;
  bool _isLeader = false;
  Set<String> _leadershipMinistries = {};
  String? _uid;

  @override
  void initState() {
    super.initState();
    _uid = _auth.currentUser?.uid;
    _primeRole();
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      setState(() => _search = _searchCtrl.text.trim().toLowerCase());
    });
  }

  Future<void> _primeRole() async {
    final uid = _uid;
    if (uid == null) return;

    final userDoc = await _db.collection('users').doc(uid).get();
    final user = userDoc.data() ?? {};
    final roles = List<String>.from(user['roles'] ?? const []);
    final memberId = user['memberId'] as String?;

    bool isAdmin = roles.contains('admin');
    bool isLeader = roles.contains('leader');
    final fromUsers = List<String>.from(user['leadershipMinistries'] ?? const []);
    final ministries = <String>{...fromUsers};

    if (memberId != null) {
      final memDoc = await _db.collection('members').doc(memberId).get();
      final mem = memDoc.data() ?? {};
      final fromMembers = List<String>.from(mem['leadershipMinistries'] ?? const []);
      ministries.addAll(fromMembers);
      if (!isAdmin && fromMembers.isNotEmpty) isLeader = true;
    }

    setState(() {
      _isAdmin = isAdmin;
      _isLeader = isLeader;
      _leadershipMinistries = ministries;
    });
  }

  // ======== Queries ========

  Stream<QuerySnapshot<Map<String, dynamic>>> _eventsStream() {
    final now = Timestamp.now();
    Query<Map<String, dynamic>> q = _db.collection('events').withConverter<Map<String, dynamic>>(
      fromFirestore: (s, _) => s.data() ?? {},
      toFirestore: (m, _) => m,
    );

    // Time scope
    if (_scope == 'Upcoming') {
      q = q.where('startDate', isGreaterThanOrEqualTo: now).orderBy('startDate');
    } else {
      q = q.where('startDate', isLessThan: now).orderBy('startDate', descending: true);
    }

    // Visibility scope
    if (_visibility == 'Church-wide') {
      // church-wide => ministryId missing/empty
      q = q.where('ministryId', whereIn: [null, '']).limit(50);
    } else if (_visibility == 'My ministries') {
      // leaders/members: ministryId is one of my leadership ministries (leaders) OR membership
      // Here we filter by leadership for management focus. If you want membership, pass your list here.
      final list = _leadershipMinistries.toList();
      if (list.isEmpty) {
        // nothing to show if no ministries
        q = q.where('ministryId', isEqualTo: '__none__'); // will produce zero results
      } else {
        // Firestore whereIn max 10 items — split if needed
        final slice = list.take(10).toList();
        q = q.where('ministryId', whereIn: slice);
      }
    } else {
      // All: no extra filter
      q = q.limit(50);
    }

    return q.snapshots();
  }

  // ======== Permissions helpers (must match your rules) ========

  bool _canManageEvent(Map<String, dynamic> e) {
    if (_isAdmin) return true;
    if (!_isLeader) return false;
    final mid = (e['ministryId'] ?? '') as String;
    // Leaders can manage BOTH church-wide (empty) and their ministries
    return mid.isEmpty || _leadershipMinistries.contains(mid);
  }

  bool _canCreate() => _isAdmin || _isLeader;

  // ======== RSVP ========

  Stream<int> _rsvpCount(String eventId) {
    return _db
        .collection('event_rsvps')
        .where('eventId', isEqualTo: eventId)
        .snapshots()
        .map((snap) => snap.size);
  }

  Stream<bool> _myRsvped(String eventId) {
    final uid = _uid;
    if (uid == null) return const Stream<bool>.empty();
    final id = '$eventId-$uid';
    return _db.collection('event_rsvps').doc(id).snapshots().map((d) => d.exists);
  }

  Future<void> _toggleRsvp(String eventId, bool on) async {
    final uid = _uid;
    if (uid == null) return;
    final id = '$eventId-$uid';
    final ref = _db.collection('event_rsvps').doc(id);
    if (on) {
      await ref.set(
        {
          'eventId': eventId,
          'userId': uid,
          'status': 'going',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } else {
      await ref.delete();
    }
  }

  // ======== Create / Edit / Delete ========

  Future<void> _deleteEvent(String eventId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete event?'),
        content: const Text('This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _db.collection('events').doc(eventId).delete();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Event deleted')));
    }
  }

  Future<void> _openEditor({DocumentSnapshot<Map<String, dynamic>>? doc}) async {
    final data = doc?.data();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => EventEditorSheet(
        existing: data,
        docId: doc?.id,
        isAdmin: _isAdmin,
        isLeader: _isLeader,
        leadershipMinistries: _leadershipMinistries.toList()..sort(),
      ),
    );
  }

  // ======== UI ========

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Events'),
        actions: [
          PopupMenuButton<String>(
            initialValue: _scope,
            onSelected: (v) => setState(() => _scope = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'Upcoming', child: Text('Upcoming')),
              PopupMenuItem(value: 'Past', child: Text('Past')),
            ],
            icon: const Icon(Icons.schedule),
            tooltip: 'Time',
          ),
          PopupMenuButton<String>(
            initialValue: _visibility,
            onSelected: (v) => setState(() => _visibility = v),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'All', child: Text('All')),
              PopupMenuItem(value: 'Church-wide', child: Text('Church-wide')),
              PopupMenuItem(value: 'My ministries', child: Text('My ministries')),
            ],
            icon: const Icon(Icons.filter_alt),
            tooltip: 'Scope',
          ),
        ],
      ),
      floatingActionButton: _canCreate()
          ? FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('New event'),
      )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search by title or description…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _eventsStream(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = (snap.data?.docs ?? []).where((d) {
                  if (_search.isEmpty) return true;
                  final m = d.data();
                  final t = (m['title'] ?? '').toString().toLowerCase();
                  final desc = (m['description'] ?? '').toString().toLowerCase();
                  final where = '$t $desc';
                  return where.contains(_search);
                }).toList();

                if (docs.isEmpty) {
                  return const Center(child: Text('No events found.'));
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final d = docs[i];
                    final e = d.data();
                    final title = (e['title'] ?? 'Untitled').toString();
                    final start = (e['startDate'] as Timestamp?)?.toDate();
                    final end = (e['endDate'] as Timestamp?)?.toDate();
                    final loc = (e['location'] ?? '').toString();
                    final desc = (e['description'] ?? '').toString();
                    final ministryId = (e['ministryId'] ?? '') as String; // '' => Church-wide
                    final canManage = _canManageEvent(e);

                    return Card(
                      elevation: 2,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Title + badges + actions
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(title,
                                          style: const TextStyle(
                                              fontSize: 16, fontWeight: FontWeight.w700)),
                                      const SizedBox(height: 4),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 6,
                                        children: [
                                          _Badge(
                                            icon: Icons.schedule,
                                            label: start != null
                                                ? _fmtDateRange(start, end)
                                                : 'Date TBC',
                                          ),
                                          if (loc.isNotEmpty)
                                            _Badge(icon: Icons.place_outlined, label: loc),
                                          Chip(
                                            label: Text(
                                              ministryId.isEmpty ? 'Church-wide' : ministryId,
                                              style: TextStyle(
                                                fontWeight: ministryId.isEmpty ? FontWeight.w700 : FontWeight.w600,
                                              ),
                                            ),
                                            avatar: Icon(
                                              ministryId.isEmpty
                                                  ? Icons.public
                                                  : Icons.groups_2_outlined,
                                              size: 18,
                                            ),
                                            backgroundColor: ministryId.isEmpty
                                                ? Colors.indigo.shade50
                                                : Colors.teal.shade50,
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(16),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                if (canManage)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: 'Edit',
                                        onPressed: () => _openEditor(doc: d),
                                        icon: const Icon(Icons.edit),
                                      ),
                                      IconButton(
                                        tooltip: 'Delete',
                                        onPressed: () => _deleteEvent(d.id),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                            if (desc.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(desc, style: TextStyle(color: Colors.grey.shade700)),
                            ],
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                StreamBuilder<bool>(
                                  stream: _myRsvped(d.id),
                                  builder: (context, s) {
                                    final joined = s.data == true;
                                    return FilledButton.icon(
                                      onPressed: () => _toggleRsvp(d.id, !joined),
                                      icon: Icon(joined ? Icons.check : Icons.event_available),
                                      label: Text(joined ? 'Going' : 'RSVP'),
                                    );
                                  },
                                ),
                                const SizedBox(width: 12),
                                StreamBuilder<int>(
                                  stream: _rsvpCount(d.id),
                                  builder: (context, s) {
                                    final count = s.data ?? 0;
                                    return Text('$count going',
                                        style: TextStyle(color: Colors.grey.shade600));
                                  },
                                )
                              ],
                            ),
                          ],
                        ),
                      ),
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

  String _fmtDateRange(DateTime start, DateTime? end) {
    final sameDay = end != null &&
        start.year == end.year && start.month == end.month && start.day == end.day;
    final date = MaterialLocalizations.of(context).formatMediumDate(start);
    final timeStart = TimeOfDay.fromDateTime(start).format(context);
    if (end == null) return '$date • $timeStart';
    final timeEnd = TimeOfDay.fromDateTime(end).format(context);
    return sameDay ? '$date • $timeStart–$timeEnd' : '$date • $timeStart → ${MaterialLocalizations.of(context).formatMediumDate(end)} • $timeEnd';
  }
}

// ======== Editor Sheet ========

class EventEditorSheet extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final String? docId;
  final bool isAdmin;
  final bool isLeader;
  final List<String> leadershipMinistries;

  const EventEditorSheet({
    super.key,
    this.existing,
    this.docId,
    required this.isAdmin,
    required this.isLeader,
    required this.leadershipMinistries,
  });

  @override
  State<EventEditorSheet> createState() => _EventEditorSheetState();
}

class _EventEditorSheetState extends State<EventEditorSheet> {
  final _db = FirebaseFirestore.instance;
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _title;
  late TextEditingController _description;
  late TextEditingController _location;
  DateTime? _start;
  DateTime? _end;
  String _ministryChoice = ''; // '' => church-wide

  List<String> _allMinistries = [];

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    _title = TextEditingController(text: e['title'] ?? '');
    _description = TextEditingController(text: e['description'] ?? '');
    _location = TextEditingController(text: e['location'] ?? '');
    _ministryChoice = (e['ministryId'] ?? '') as String;
    _start = (e['startDate'] as Timestamp?)?.toDate();
    _end = (e['endDate'] as Timestamp?)?.toDate();
    _loadMinistryNames();
  }

  Future<void> _loadMinistryNames() async {
    // Admin can pick any ministry; leader only their own list
    if (widget.isAdmin) {
      final qs = await _db.collection('ministries').get();
      setState(() => _allMinistries =
      qs.docs.map((d) => (d.data()['name'] ?? '').toString()).where((s) => s.isNotEmpty).toList()
        ..sort());
    } else if (widget.isLeader) {
      setState(() => _allMinistries = [...widget.leadershipMinistries]..sort());
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime({required bool start}) async {
    final now = DateTime.now();
    final init = start ? (_start ?? now.add(const Duration(hours: 2))) : (_end ?? _start ?? now.add(const Duration(hours: 3)));

    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
      initialDate: init,
    );
    if (date == null) return;

    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(init));
    if (time == null) return;

    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (start) {
        _start = dt;
        if (_end != null && _end!.isBefore(_start!)) _end = _start!.add(const Duration(hours: 1));
      } else {
        _end = dt;
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_start == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please pick a start date/time')));
      return;
    }
    if (_end != null && _end!.isBefore(_start!)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('End must be after start')));
      return;
    }

    final payload = {
      'title': _title.text.trim(),
      'description': _description.text.trim(),
      'location': _location.text.trim(),
      'startDate': Timestamp.fromDate(_start!),
      'endDate': _end != null ? Timestamp.fromDate(_end!) : null,
      // IMPORTANT: '' indicates Church-wide. Your rules must allow leaders when empty.
      'ministryId': _ministryChoice, // '' or ministry NAME
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (widget.docId == null) {
      await _db.collection('events').add({
        ...payload,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Event created')));
    } else {
      await _db.collection('events').doc(widget.docId).update(payload);
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Event updated')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPickMinistry = widget.isAdmin || widget.isLeader;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Row(
              children: [
                Text(widget.docId == null ? 'New Event' : 'Edit Event',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _description,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _location,
              decoration: const InputDecoration(labelText: 'Location', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDateTime(start: true),
                    icon: const Icon(Icons.schedule),
                    label: Text(_start == null
                        ? 'Pick start'
                        : '${MaterialLocalizations.of(context).formatFullDate(_start!)} • ${TimeOfDay.fromDateTime(_start!).format(context)}'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickDateTime(start: false),
                    icon: const Icon(Icons.schedule_send),
                    label: Text(_end == null
                        ? 'Pick end (optional)'
                        : '${MaterialLocalizations.of(context).formatFullDate(_end!)} • ${TimeOfDay.fromDateTime(_end!).format(context)}'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (canPickMinistry)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Visibility / Ownership', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: _ministryChoice,
                    items: [
                      const DropdownMenuItem(value: '', child: Text('Church-wide')),
                      ..._allMinistries.map((m) => DropdownMenuItem(value: m, child: Text(m))),
                    ],
                    onChanged: (v) => setState(() => _ministryChoice = v ?? ''),
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                  ),
                ],
              ),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save')),
          ],
        ),
      ),
    );
  }
}

// ======== Small UI helper ========
class _Badge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Badge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade700),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: Colors.grey.shade800)),
        ],
      ),
    );
  }
}
