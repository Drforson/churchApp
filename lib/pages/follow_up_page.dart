import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

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

  // Search
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  String _searchMode = 'prefix'; // prefix | exact

  // Filters
  List<String> _ministryOptions = const ['All'];
  String _selectedMinistry = 'All';
  String _selectedGender = 'all';

  // Absentees (server-side list)
  final Map<String, List<Map<String, dynamic>>> _absentLists = {
    'member': [],
    'visitor': [],
  };
  final Map<String, Map<String, dynamic>?> _absentCursor = {
    'member': null,
    'visitor': null,
  };
  final Map<String, bool> _absentHasMore = {
    'member': true,
    'visitor': true,
  };
  final Map<String, bool> _absentLoading = {
    'member': false,
    'visitor': false,
  };
  static const int _absentPageSize = 50;

  // Summary (server-side aggregates)
  Map<String, dynamic>? _summary;
  bool _summaryLoading = false;
  String? _summaryError;

  // Tabs
  late TabController _tabController;

  // UI
  bool _loadingInitial = true;
  String _statusMessage = 'Checking attendance...';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      _loadAbsenteesForCurrentTab(reset: false);
    });
    _primeRole().then((_) {
      _loadMinistryOptions();
      _loadAvailableWindows();
    });
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
          _statusMessage =
              _availableWindows.isEmpty ? 'No attendance records yet.' : 'Loaded services.';
        });
        if (_selectedWindowId != null) {
          await _loadSummary();
          _resetAbsentees();
          _loadAbsenteesForCurrentTab(reset: true);
        }
        return;
      }
      setState(() {
        _availableWindows = windows;
        _selectedWindowId = windows.isNotEmpty ? windows.first.id : null;
        _statusMessage = windows.isEmpty ? 'No attendance records yet.' : 'Loaded services.';
      });
      if (_selectedWindowId != null) {
        await _loadSummary();
        _resetAbsentees();
        _loadAbsenteesForCurrentTab(reset: true);
      }
    } catch (e) {
      setState(() => _statusMessage = 'Error fetching services: $e');
    }
  }

  Future<void> _loadMinistryOptions() async {
    try {
      final snap = await _db.collection('ministries').orderBy('name').limit(300).get();
      final names = snap.docs
          .map((d) => (d.data()['name'] ?? '').toString().trim())
          .where((n) => n.isNotEmpty)
          .toList();
      setState(() => _ministryOptions = ['All', ...names]);
    } catch (_) {
      setState(() => _ministryOptions = const ['All']);
    }
  }

  Future<void> _loadSummary() async {
    final win = _selectedWindow;
    if (win == null) return;
    setState(() {
      _summaryLoading = true;
      _summaryError = null;
    });
    try {
      final res = await FirebaseFunctions.instanceFor(region: 'europe-west2')
          .httpsCallable('getFollowUpSummary')
          .call({
        'dateKey': win.dateKey,
        'windowId': win.id,
      });
      final data = res.data;
      if (mounted) {
        setState(() {
          _summary = data is Map ? Map<String, dynamic>.from(data) : null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _summaryError = e.toString());
    } finally {
      if (mounted) setState(() => _summaryLoading = false);
    }
  }

  /* ------------------------- SEARCH ------------------------- */

  String _searchQuery = '';
  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final q = _searchCtrl.text.trim().toLowerCase();
      setState(() => _searchQuery = q);
      _resetAbsentees();
      _loadAbsenteesForCurrentTab(reset: true);
    });
  }

  void _resetAbsentees() {
    _absentLists['member'] = [];
    _absentLists['visitor'] = [];
    _absentCursor['member'] = null;
    _absentCursor['visitor'] = null;
    _absentHasMore['member'] = true;
    _absentHasMore['visitor'] = true;
  }

  String _currentType() => _tabController.index == 0 ? 'member' : 'visitor';

  Future<void> _loadAbsenteesForCurrentTab({required bool reset}) async {
    await _loadAbsentees(type: _currentType(), reset: reset);
  }

  Future<void> _loadAbsentees({required String type, required bool reset}) async {
    if (_absentLoading[type] == true) return;
    if (!reset && _absentHasMore[type] == false) return;
    final win = _selectedWindow;
    if (win == null) return;

    setState(() => _absentLoading[type] = true);
    if (reset) {
      _absentLists[type] = [];
      _absentCursor[type] = null;
      _absentHasMore[type] = true;
    }

    try {
      final res = await FirebaseFunctions.instanceFor(region: 'europe-west2')
          .httpsCallable('listFollowUpAbsentees')
          .call({
        'dateKey': win.dateKey,
        'windowId': win.id,
        'type': type,
        'gender': _selectedGender,
        'ministryName': _selectedMinistry == 'All' ? null : _selectedMinistry,
        'query': _searchQuery,
        'matchMode': _searchMode,
        'limit': _absentPageSize,
        'cursor': _absentCursor[type],
      });
      final data = res.data is Map ? Map<String, dynamic>.from(res.data) : <String, dynamic>{};
      final items = (data['results'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final cursor = data['cursor'] is Map ? Map<String, dynamic>.from(data['cursor']) : null;
      final hasMore = data['hasMore'] == true;

      setState(() {
        final current = _absentLists[type] ?? const <Map<String, dynamic>>[];
        _absentLists[type] = [...current, ...items];
        _absentCursor[type] = cursor;
        _absentHasMore[type] = hasMore;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load absentees: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _absentLoading[type] = false);
    }
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
      body: _loadingInitial
          ? const Center(child: CircularProgressIndicator())
          : _selectedWindowId == null || _selectedWindow == null
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
                  onChanged: (newId) {
                    setState(() => _selectedWindowId = newId);
                    _loadSummary();
                  },
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
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _searchMode,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Search Mode',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'prefix', child: Text('Starts with')),
                    DropdownMenuItem(value: 'exact', child: Text('Exact match')),
                  ],
                  onChanged: (v) {
                    setState(() => _searchMode = v ?? 'prefix');
                    _resetAbsentees();
                    _loadAbsenteesForCurrentTab(reset: true);
                  },
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
              final role = (data['role'] ?? '').toString();
              final roleLower = role.toLowerCase().trim();
              final isPastorFlag = data['isPastor'] == true;
              final hasAdmin = roles.map((e) => e.toLowerCase()).contains('admin') || roleLower == 'admin';
              final hasPastor = roles.map((e) => e.toLowerCase()).contains('pastor') || roleLower == 'pastor' || isPastorFlag;
              final hasLeader = roles.map((e) => e.toLowerCase()).contains('leader') || roleLower == 'leader';
              final memberId = (data['memberId'] ?? '').toString();
              final uid = FirebaseAuth.instance.currentUser?.uid ?? 'unknown';
              final roleText = hasAdmin
                  ? 'Admin'
                  : hasPastor
                  ? 'Pastor'
                  : hasLeader
                  ? 'Leader'
                  : 'Member';
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Chip(
                        label: Text('Role: $roleText'),
                        avatar: Icon(
                          hasAdmin ? Icons.security : hasPastor ? Icons.church : hasLeader ? Icons.verified : Icons.person,
                          size: 18,
                        ),
                      ),
                      if (!kReleaseMode)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'UID: $uid\nrole: ${role.isEmpty ? '—' : role}\nmemberId: ${memberId.isEmpty ? '—' : memberId}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                          ),
                        ),
                    ],
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
                final noRecords = records.isEmpty;

                final summary = _summary ?? {};
                final totalMembers = (summary['totalMembers'] as int?) ?? 0;
                final totalVisitors = (summary['totalVisitors'] as int?) ?? 0;
                final presentMembers = (summary['presentMembers'] as int?) ?? 0;
                final presentVisitors = (summary['presentVisitors'] as int?) ?? 0;
                final absentMembersCount = (summary['absentMembers'] as int?) ??
                    (totalMembers - presentMembers);
                final absentVisitorsCount = (summary['absentVisitors'] as int?) ??
                    (totalVisitors - presentVisitors);
                final malePresent = summary['malePresent'] ?? 0;
                final femalePresent = summary['femalePresent'] ?? 0;
                final unknownPresent = summary['unknownPresent'] ?? 0;
                final maleAbsent = summary['maleAbsent'] ?? 0;
                final femaleAbsent = summary['femaleAbsent'] ?? 0;
                final unknownAbsent = summary['unknownAbsent'] ?? 0;
                final memberAttendanceRate =
                    totalMembers == 0 ? 0.0 : (presentMembers / totalMembers * 100);
                final visitorAttendanceRate =
                    totalVisitors == 0 ? 0.0 : (presentVisitors / totalVisitors * 100);

                return NestedScrollView(
                  headerSliverBuilder: (context, innerBoxIsScrolled) {
                    return [
                      if (noRecords)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                            child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.shade50,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: Colors.amber.shade200),
                                  ),
                                  child: const Text(
                                    'No attendance records found for this service yet.',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: _selectedMinistry,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Ministry',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: _ministryOptions
                                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                                      .toList(),
                                  onChanged: (v) {
                                    setState(() => _selectedMinistry = v ?? 'All');
                                    _resetAbsentees();
                                    _loadAbsenteesForCurrentTab(reset: true);
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: _selectedGender,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Gender',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: const [
                                    DropdownMenuItem(value: 'all', child: Text('All')),
                                    DropdownMenuItem(value: 'male', child: Text('Male')),
                                    DropdownMenuItem(value: 'female', child: Text('Female')),
                                    DropdownMenuItem(value: 'other', child: Text('Other')),
                                  ],
                                  onChanged: (v) {
                                    setState(() => _selectedGender = v ?? 'all');
                                    _resetAbsentees();
                                    _loadAbsenteesForCurrentTab(reset: true);
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_summaryLoading)
                        const SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: LinearProgressIndicator(minHeight: 2),
                              ),
                            ),
                          if (_summaryError != null)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                child: Text(
                                  'Summary error: $_summaryError',
                                  style: TextStyle(color: Colors.red.shade700),
                                ),
                              ),
                            ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                              child: _StatsGridCompact(
                                items: [
                                  _StatData('Total Members', totalMembers, Icons.groups, Colors.blueGrey),
                                  _StatData('Total Visitors', totalVisitors, Icons.person_outline, Colors.teal),
                                  _StatData('Absent Members', absentMembersCount, Icons.group_off, Colors.red),
                                  _StatData('Absent Visitors', absentVisitorsCount, Icons.person_off, Colors.orange),
                                  _StatData('Male Present', malePresent, Icons.male, Colors.green),
                                  _StatData('Female Present', femalePresent, Icons.female, Colors.pink),
                                  _StatData('Male Absent', maleAbsent, Icons.male, Colors.redAccent),
                                  _StatData('Female Absent', femaleAbsent, Icons.female, Colors.deepOrange),
                                  _StatData('Unknown Present', unknownPresent, Icons.help_outline, Colors.indigo),
                                  _StatData('Unknown Absent', unknownAbsent, Icons.help_outline, Colors.deepPurple),
                                  _StatData('Member Rate', memberAttendanceRate, Icons.insights, Colors.green, isPercent: true),
                                  _StatData('Visitor Rate', visitorAttendanceRate, Icons.pie_chart_outline, Colors.teal, isPercent: true),
                                ],
                              ),
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
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
                          ),
                          const SliverToBoxAdapter(child: SizedBox(height: 6)),
                        ];
                      },
                      body: TabBarView(
                        controller: _tabController,
                        children: [
                          _PeopleList(
                            people: _absentLists['member'] ?? const [],
                            titleBuilder: (m) => '${m['firstName'] ?? ''} ${m['lastName'] ?? ''}'.trim(),
                            subtitle: 'Member',
                            onTap: _openContactSheet,
                            loadingMore: _absentLoading['member'] == true,
                            hasMore: _absentHasMore['member'] == true,
                            onLoadMore: () => _loadAbsentees(type: 'member', reset: false),
                            emptyMessage: _absentLoading['member'] == true
                                ? 'Loading...'
                                : 'Nobody in this list 🎉',
                          ),
                          _PeopleList(
                            people: _absentLists['visitor'] ?? const [],
                            titleBuilder: (v) => '${v['firstName'] ?? ''} ${v['lastName'] ?? ''}'.trim(),
                            subtitle: 'Visitor',
                            onTap: _openContactSheet,
                            loadingMore: _absentLoading['visitor'] == true,
                            hasMore: _absentHasMore['visitor'] == true,
                            onLoadMore: () => _loadAbsentees(type: 'visitor', reset: false),
                            emptyMessage: _absentLoading['visitor'] == true
                                ? 'Loading...'
                                : 'Nobody in this list 🎉',
                          ),
                        ],
                      ),
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
  final bool loadingMore;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final String emptyMessage;

  const _PeopleList({
    required this.people,
    required this.titleBuilder,
    required this.subtitle,
    required this.onTap,
    this.loadingMore = false,
    this.hasMore = false,
    this.onLoadMore,
    this.emptyMessage = 'Nobody in this list 🎉',
  });

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(emptyMessage, style: Theme.of(context).textTheme.bodyLarge),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: people.length + (hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        if (hasMore && i == people.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: loadingMore
                  ? const CircularProgressIndicator()
                  : TextButton.icon(
                      onPressed: onLoadMore,
                      icon: const Icon(Icons.add),
                      label: const Text('Load more'),
                    ),
            ),
          );
        }
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
