import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';

class FollowUpPage extends StatefulWidget {
  const FollowUpPage({super.key});

  @override
  State<FollowUpPage> createState() => _FollowUpPageState();
}

class _FollowUpPageState extends State<FollowUpPage> with SingleTickerProviderStateMixin {
  final _db = FirebaseFirestore.instance;

  // Role
  final bool _isAdmin = false;
  final bool _isLeader = false;
  final Set<String> _leadershipMinistries = {};

  // Service windows
  String? _selectedWindowId;
  List<_AttendanceWindow> _availableWindows = [];
  bool _usingWindowFallback = false;

  // Search
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  // Tabs
  late TabController _tabController;

  // UI
  bool _loadingInitial = true;
  String _statusMessage = 'Checking attendance...';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _primeRole().then((_) => _loadAvailableWindows());
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _tabController.dispose();
    super.dispose();
  }

  /* ------------------------- ROLE ------------------------- */

  Future<void> _primeRole() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        setState(() => _loadingInitial = false);
        return;
      }

      // Ensure the user doc/role link exists so Firestore rules can validate.
      try {
        await FirebaseFunctions.instanceFor(region: 'europe-west2')
            .httpsCallable('ensureUserDoc')
            .call();
      } catch (_) {}

      try {
        await FirebaseFunctions.instanceFor(region: 'europe-west2')
            .httpsCallable('syncUserRoleFromMemberOnLogin')
            .call();
      } catch (_) {}

      try {
        await user.getIdToken(true);
      } catch (_) {}
    } finally {
      if (mounted) setState(() => _loadingInitial = false);
    }
  }

  /* ------------------------- DATES ------------------------- */

  Future<void> _loadAvailableWindows() async {
    try {
      final snap = await _db
          .collection('attendance_windows')
          .orderBy('startsAt', descending: true)
          .limit(200)
          .get();
      final windows = snap.docs.map(_AttendanceWindow.fromDoc).toList();

      if (windows.isEmpty) {
        // Fallback: build pseudo windows from attendance dates
        final attSnap = await _db.collection('attendance').get();
        final keys = attSnap.docs.map((d) => d.id).toList()
          ..sort((a, b) => b.compareTo(a));
        setState(() {
          _availableWindows = keys
              .map((k) => _AttendanceWindow.fallback(dateKey: k))
              .toList();
          _selectedWindowId =
              _availableWindows.isNotEmpty ? _availableWindows.first.id : null;
          _usingWindowFallback = true;
          _statusMessage =
              _availableWindows.isEmpty ? 'No attendance records yet.' : 'Loaded services.';
        });
        return;
      }
      setState(() {
        _availableWindows = windows;
        _selectedWindowId = windows.isNotEmpty ? windows.first.id : null;
        _usingWindowFallback = false;
        _statusMessage = windows.isEmpty ? 'No attendance records yet.' : 'Loaded services.';
      });
    } catch (e) {
      setState(() => _statusMessage = 'Error fetching services: $e');
    }
  }

  /* ------------------------- SEARCH ------------------------- */

  String _searchQuery = '';
  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
    });
  }

  /* ------------------------- HELPERS ------------------------- */

  _AttendanceWindow? get _selectedWindow {
    if (_selectedWindowId == null) return null;
    try {
      return _availableWindows.firstWhere((w) => w.id == _selectedWindowId);
    } catch (_) {
      return null;
    }
  }

  String _bestPhone(Map<String, dynamic> m) {
    final p1 = (m['phone'] ?? '').toString();
    final p2 = (m['phoneNumber'] ?? '').toString();
    return p1.isNotEmpty ? p1 : p2;
  }

  bool _matchesQuery(Map<String, dynamic> m) {
    if (_searchQuery.isEmpty) return true;
    final name = '${m['firstName'] ?? ''} ${m['lastName'] ?? ''}'.trim().toLowerCase();
    final phone = _bestPhone(m).toLowerCase();
    return name.contains(_searchQuery) || phone.contains(_searchQuery);
  }

  List<String> _weekRangeLabels(DateTime selected) {
    final start = selected.subtract(const Duration(days: 6));
    return List.generate(7, (i) => DateFormat('MMM d').format(start.add(Duration(days: i))));
  }

  bool _recordMatchesWindow(
    Map<String, dynamic> data,
    _AttendanceWindow w,
  ) {
    final windowId = (data['windowId'] ?? '').toString().trim();
    if (windowId.isNotEmpty) return windowId == w.id;
    // No windowId on record (legacy/manual).
    // Only include when we're in fallback mode (date-based).
    return _usingWindowFallback && w.dateKey.isNotEmpty;
  }

  bool _isPresentRecord(Map<String, dynamic> data) {
    final status = (data['status'] ?? '').toString().toLowerCase();
    if (status == 'present') return true;
    if (status == 'absent') return false;
    if (data['present'] == true) return true;
    if (data['present'] == false) return false;
    final result = (data['result'] ?? '').toString().toLowerCase();
    if (result == 'present') return true;
    if (result == 'absent') return false;
    return false;
  }

  /* ------------------------- CONTACT ------------------------- */

  Future<void> _callNumber(String number) async {
    final uri = Uri.parse('tel:$number');
    await launchUrl(uri);
  }

  Future<void> _sendSMS(String number, String message) async {
    final uri = Uri.parse('sms:$number?body=${Uri.encodeComponent(message)}');
    await launchUrl(uri);
  }

  Future<void> _openWhatsApp(String number, String message) async {
    final uri = Uri.parse('https://wa.me/$number?text=${Uri.encodeComponent(message)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /* ------------------------- UI ------------------------- */

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFE3E7EE),
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
        centerTitle: true,
        title: const Text('Follow-Up Summary'),
      ),
      body: _selectedWindowId == null || _selectedWindow == null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_statusMessage)))
          : Column(
        children: [
          // Date & Search Row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Column(
              children: [
                _DateDropdown(
                  windows: _availableWindows,
                  value: _selectedWindowId!,
                  onChanged: (newId) => setState(() => _selectedWindowId = newId),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _searchCtrl,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search absent people…',
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),

          // Live role chip (reads current user's doc; shows Admin/Leader for readability)
          StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('users')
                .doc(FirebaseAuth.instance.currentUser!.uid)
                .snapshots(),
            builder: (context, snap) {
              final data = snap.data?.data() as Map<String, dynamic>? ?? {};
              final roles = List<String>.from(data['roles'] ?? const []);
              final roleText = roles.contains('admin')
                  ? 'Admin'
                  : roles.contains('leader')
                  ? 'Leader'
                  : 'Member';
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Chip(
                    label: Text('Role: $roleText'),
                    avatar: Icon(
                      roles.contains('admin') ? Icons.security : roles.contains('leader') ? Icons.verified : Icons.person,
                      size: 18,
                    ),
                  ),
                ),
              );
            },
          ),

          // Stats + Lists (realtime)
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _db
                  .collection('attendance')
                  .doc(_selectedWindow!.dateKey)
                  .collection('records')
                  .snapshots(),
              builder: (context, recordsSnap) {
                final records = recordsSnap.data?.docs ?? const [];
                final Map<String, bool> presentMap = {};
                for (final r in records) {
                  final data = r.data() as Map<String, dynamic>;
                  if (!_recordMatchesWindow(data, _selectedWindow!)) continue;
                  final mid = (data['memberId'] ?? r.id).toString();
                  if (mid.isEmpty) continue;
                  presentMap[mid] = _isPresentRecord(data);
                }
                final presentIds = presentMap.entries
                    .where((e) => e.value == true)
                    .map((e) => e.key)
                    .toSet();

                return StreamBuilder<QuerySnapshot>(
                  stream: _db.collection('members').snapshots(),
                  builder: (context, membersSnap) {
                    if (!membersSnap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final allMembers = membersSnap.data!.docs
                        .map((d) => {'id': d.id, ...(d.data() as Map<String, dynamic>)})
                        .toList();

                    final confirmedMembers = allMembers.where((m) => m['isVisitor'] != true).toList();
                    final visitors = allMembers.where((m) => m['isVisitor'] == true).toList();

                    // Optional: If you want leaders to only see their ministries, filter here by ministry name overlap
                    // (Uncomment to restrict leader view)
                    // final leaderMins = _leadershipMinistries;
                    // final filterByLeader = (Map<String, dynamic> m) {
                    //   if (_isAdmin) return true;
                    //   if (!_isLeader) return true;
                    //   final mins = List<String>.from(m['ministries'] ?? const []);
                    //   return mins.any((x) => leaderMins.contains(x));
                    // };
                    // confirmedMembers.retainWhere(filterByLeader);
                    // visitors.retainWhere(filterByLeader);

                    // Absentees
                    final absentMembers = confirmedMembers.where((m) => !presentIds.contains(m['id'])).toList();
                    final absentVisitors = visitors.where((v) => !presentIds.contains(v['id'])).toList();

                    // Search filter
                    final filteredMembers = absentMembers.where(_matchesQuery).toList();
                    final filteredVisitors = absentVisitors.where(_matchesQuery).toList();

                    // Stats
                    final presentMembers = confirmedMembers.where((m) => presentIds.contains(m['id'])).length;
                    final presentVisitors = visitors.where((v) => presentIds.contains(v['id'])).length;
                    final totalMembers = confirmedMembers.length;
                    final totalVisitors = visitors.length;

                    int malePresent = 0, femalePresent = 0, maleAbsent = 0, femaleAbsent = 0;
                    String genderOf(Map<String, dynamic> m) =>
                        (m['gender'] ?? '').toString().toLowerCase().trim();
                    bool isMale(Map<String, dynamic> m) => genderOf(m).startsWith('m');
                    bool isFemale(Map<String, dynamic> m) => genderOf(m).startsWith('f');

                    for (final m in confirmedMembers) {
                      final isPresent = presentIds.contains(m['id']);
                      if (isMale(m)) {
                        if (isPresent) {
                          malePresent++;
                        } else {
                          maleAbsent++;
                        }
                      } else if (isFemale(m)) {
                        if (isPresent) {
                          femalePresent++;
                        } else {
                          femaleAbsent++;
                        }
                      }
                    }

                    final memberAttendanceRate =
                    confirmedMembers.isEmpty ? 0.0 : (presentMembers / confirmedMembers.length * 100);
                    final visitorAttendanceRate =
                    visitors.isEmpty ? 0.0 : (presentVisitors / visitors.length * 100);

                    // New members (on selected date)
                    DateTime? selectedDate;
                    try {
                      final parts = _selectedWindow!.dateKey.split('-').map(int.parse).toList();
                      selectedDate = DateTime(parts[0], parts[1], parts[2]);
                    } catch (_) {}
                    final newMembersCount = confirmedMembers.where((m) {
                      final ts = m['createdAt'] as Timestamp?;
                      if (ts == null || selectedDate == null) return false;
                      final created = ts.toDate();
                      return created.year == selectedDate.year &&
                          created.month == selectedDate.month &&
                          created.day == selectedDate.day;
                    }).length;

                    // Birthdays in selected week
                    final weekStart = selectedDate?.subtract(const Duration(days: 6));
                    final birthdayCount = confirmedMembers.where((m) {
                      final ts = m['dateOfBirth'] as Timestamp?;
                      if (ts == null || selectedDate == null || weekStart == null) return false;
                      final b = ts.toDate();
                      // compare by month/day
                      final inRange = !b.isBefore(weekStart) && !b.isAfter(selectedDate);
                      return inRange && (b.month == selectedDate.month); // keep same month check (optional)
                    }).length;

                    return Column(
                      children: [
                        // Fancy stats
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: _StatsGridCompact(
                            items: [
                              _StatData('Total Members', totalMembers, Icons.groups, Colors.blueGrey),
                              _StatData('Total Visitors', totalVisitors, Icons.person_outline, Colors.teal),
                              _StatData('Absent Members', filteredMembers.length, Icons.group_off, Colors.red),
                              _StatData('Absent Visitors', filteredVisitors.length, Icons.person_off, Colors.orange),
                              _StatData('Male Present', malePresent, Icons.male, Colors.green),
                              _StatData('Female Present', femalePresent, Icons.female, Colors.pink),
                              _StatData('Male Absent', maleAbsent, Icons.male, Colors.redAccent),
                              _StatData('Female Absent', femaleAbsent, Icons.female, Colors.deepOrange),
                              _StatData('Member Rate', memberAttendanceRate, Icons.insights, Colors.green, isPercent: true),
                              _StatData('Visitor Rate', visitorAttendanceRate, Icons.pie_chart_outline, Colors.teal, isPercent: true),
                              _StatData('New Members', newMembersCount, Icons.person_add, Colors.blue),
                              _StatData('Birthdays', birthdayCount, Icons.cake, Theme.of(context).colorScheme.secondary),
                            ],
                          ),
                        ),

                        // Tabs
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0),
                          child: TabBar(
                            controller: _tabController,
                            labelColor: Theme.of(context).colorScheme.primary,
                            unselectedLabelColor: Colors.black54,
                            indicatorColor: Theme.of(context).colorScheme.primary,
                            tabs: const [
                              Tab(text: 'Members Absent'),
                              Tab(text: 'Visitors Absent'),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),

                        // Lists
                        Expanded(
                          child: TabBarView(
                            controller: _tabController,
                            children: [
                              _PeopleList(
                                people: filteredMembers,
                                titleBuilder: (m) => '${m['firstName'] ?? ''} ${m['lastName'] ?? ''}'.trim(),
                                subtitle: 'Member',
                                onTap: _openContactSheet,
                              ),
                              _PeopleList(
                                people: filteredVisitors,
                                titleBuilder: (v) => '${v['firstName'] ?? ''} ${v['lastName'] ?? ''}'.trim(),
                                subtitle: 'Visitor',
                                onTap: _openContactSheet,
                              ),
                            ],
                          ),
                        ),
                      ],
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

  void _openContactSheet(Map<String, dynamic> person) {
    final name = '${person['firstName'] ?? ''} ${person['lastName'] ?? ''}'.trim();
    final phone = _bestPhone(person);
    final emergency = (person['emergencyContactNumber'] ?? '').toString();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => _ContactSheet(
        name: name.isEmpty ? 'Unknown' : name,
        phone: phone,
        emergency: emergency,
        onCall: _callNumber,
        onSMS: _sendSMS,
        onWhatsApp: _openWhatsApp,
      ),
    );
  }
}

/* ======================= Widgets ======================= */

class _DateDropdown extends StatelessWidget {
  final List<_AttendanceWindow> windows;
  final String value;
  final ValueChanged<String> onChanged;

  const _DateDropdown({required this.windows, required this.value, required this.onChanged});

  String _labelFor(_AttendanceWindow w) {
    final when = w.startsAt != null
        ? DateFormat('EEE, MMM d • h:mm a').format(w.startsAt!)
        : w.dateKey;
    return w.title.isNotEmpty ? '${w.title} — $when' : when;
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Service',
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
      items: windows.map((w) {
        return DropdownMenuItem(value: w.id, child: Text(_labelFor(w)));
      }).toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _StatData {
  final String label;
  final num value;
  final IconData icon;
  final Color color;
  final bool isPercent;
  const _StatData(this.label, this.value, this.icon, this.color, {this.isPercent = false});
}

class _StatsGridCompact extends StatelessWidget {
  final List<_StatData> items;
  const _StatsGridCompact({required this.items});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth >= 900 ? 3 : 2;
      final ratio = cols == 3 ? 3.6 : 2.7; // nice, wide stat pills (no overflow)
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: items.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: ratio,
        ),
        itemBuilder: (context, i) => _StatPill(data: items[i]),
      );
    });
  }
}

class _StatPill extends StatelessWidget {
  final _StatData data;
  const _StatPill({required this.data});

  @override
  Widget build(BuildContext context) {
    final v = data.isPercent ? '${data.value.toStringAsFixed(1)}%' : data.value.toString();
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 5))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: data.color.withOpacity(0.12),
            child: Icon(data.icon, color: data.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              data.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              v,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _PeopleList extends StatelessWidget {
  final List<Map<String, dynamic>> people;
  final String Function(Map<String, dynamic>) titleBuilder;
  final String subtitle;
  final void Function(Map<String, dynamic>) onTap;

  const _PeopleList({
    required this.people,
    required this.titleBuilder,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Nobody in this list 🎉', style: Theme.of(context).textTheme.bodyLarge),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: people.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final p = people[i];
        final title = titleBuilder(p);
        final phone = (p['phone'] ?? p['phoneNumber'] ?? '').toString();
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onTap(p),
          child: Ink(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 8, offset: const Offset(0, 4))],
            ),
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: subtitle == 'Visitor' ? Colors.orange[100] : Colors.red[100],
                child: Icon(Icons.person_off, color: subtitle == 'Visitor' ? Colors.orange : Colors.red),
              ),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (phone.isNotEmpty) IconButton(icon: const Icon(Icons.call), onPressed: () => launchUrl(Uri.parse('tel:$phone'))),
                  const Icon(Icons.arrow_forward_ios, size: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ContactSheet extends StatefulWidget {
  final String name;
  final String phone;
  final String emergency;
  final Future<void> Function(String) onCall;
  final Future<void> Function(String, String) onSMS;
  final Future<void> Function(String, String) onWhatsApp;

  const _ContactSheet({
    required this.name,
    required this.phone,
    required this.emergency,
    required this.onCall,
    required this.onSMS,
    required this.onWhatsApp,
  });

  @override
  State<_ContactSheet> createState() => _ContactSheetState();
}

class _ContactSheetState extends State<_ContactSheet> {
  final TextEditingController _msgCtrl = TextEditingController();

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phone = widget.phone;
    final emerg = widget.emergency;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16, right: 16, top: 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: Text(widget.name, style: Theme.of(context).textTheme.titleLarge)),
            const SizedBox(height: 10),

            if (phone.isNotEmpty)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.phone, color: Colors.green),
                  title: Text(phone, style: const TextStyle(color: Colors.blue)),
                  onTap: () => widget.onCall(phone),
                ),
              ),
            if (emerg.isNotEmpty)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.local_hospital, color: Colors.red),
                  title: Text(emerg, style: const TextStyle(color: Colors.red)),
                  onTap: () => widget.onCall(emerg),
                ),
              ),
            const SizedBox(height: 12),

            Text('Send a message', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            TextField(
              controller: _msgCtrl,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Write your message…',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.sms),
                    label: const Text('SMS'),
                    onPressed: phone.isEmpty || _msgCtrl.text.trim().isEmpty
                        ? null
                        : () => widget.onSMS(phone, _msgCtrl.text.trim()),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const FaIcon(FontAwesomeIcons.whatsapp),
                    label: const Text('WhatsApp'),
                    onPressed: phone.isEmpty || _msgCtrl.text.trim().isEmpty
                        ? null
                        : () => widget.onWhatsApp(phone, _msgCtrl.text.trim()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _AttendanceWindow {
  final String id;
  final String title;
  final String dateKey;
  final DateTime? startsAt;
  final DateTime? endsAt;

  const _AttendanceWindow({
    required this.id,
    required this.title,
    required this.dateKey,
    this.startsAt,
    this.endsAt,
  });

  static _AttendanceWindow fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final starts = data['startsAt'] as Timestamp?;
    final ends = data['endsAt'] as Timestamp?;
    return _AttendanceWindow(
      id: doc.id,
      title: (data['title'] ?? 'Service').toString(),
      dateKey: (data['dateKey'] ?? '').toString(),
      startsAt: starts?.toDate(),
      endsAt: ends?.toDate(),
    );
  }

  static _AttendanceWindow fallback({required String dateKey}) {
    DateTime? parsed;
    try {
      parsed = DateTime.parse(dateKey);
    } catch (_) {}
    return _AttendanceWindow(
      id: dateKey,
      title: 'Service',
      dateKey: dateKey,
      startsAt: parsed,
      endsAt: null,
    );
  }
}
