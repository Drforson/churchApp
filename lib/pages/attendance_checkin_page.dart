import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../services/member_search_service.dart';

class AttendanceCheckInPage extends StatefulWidget {
  const AttendanceCheckInPage({super.key});

  @override
  State<AttendanceCheckInPage> createState() => _AttendanceCheckInPageState();
}

class _AttendanceCheckInPageState extends State<AttendanceCheckInPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  Map<String, bool> attendanceStatus = {};
  String _searchQuery = "";
  bool _submitting = false;
  List<_AttendanceWindow> _windows = [];
  String? _selectedWindowId;
  bool _loadingWindows = true;
  final List<Map<String, dynamic>> _members = [];
  QueryDocumentSnapshot? _lastMemberDoc;
  bool _loadingMembers = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  static const int _pageSize = 200;
  final List<Map<String, dynamic>> _searchResults = [];
  bool _searchLoading = false;
  Timer? _searchDebounce;
  List<String> _ministryOptions = const ['All'];
  String _selectedMinistry = 'All';
  String _selectedGender = 'all';
  String _selectedVisitor = 'all';

  String get _todayKey {
    final now = DateTime.now();
    return DateFormat('yyyy-MM-dd').format(now);
  }

  _AttendanceWindow? get _selectedWindow {
    if (_selectedWindowId == null) return null;
    try {
      return _windows.firstWhere((w) => w.id == _selectedWindowId);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _loadWindows();
    _loadInitialMembers();
    _loadMinistryOptions();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadWindows() async {
    try {
      final todaySnap = await _firestore
          .collection('attendance_windows')
          .where('dateKey', isEqualTo: _todayKey)
          .get();
      var wins = todaySnap.docs.map(_AttendanceWindow.fromDoc).toList();
      if (wins.isEmpty) {
        final recent = await _firestore
            .collection('attendance_windows')
            .orderBy('startsAt', descending: true)
            .limit(10)
            .get();
        wins = recent.docs.map(_AttendanceWindow.fromDoc).toList();
      }
      if (mounted) {
        setState(() {
          _windows = wins;
          _selectedWindowId = wins.isNotEmpty ? wins.first.id : null;
          _loadingWindows = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingWindows = false);
      }
    }
  }

  Future<void> _loadInitialMembers() async {
    setState(() {
      _members.clear();
      _lastMemberDoc = null;
      _hasMore = true;
      _loadingMembers = true;
    });
    await _loadMoreMembers();
    if (mounted) setState(() => _loadingMembers = false);
  }

  Future<void> _loadMinistryOptions() async {
    try {
      final snap = await _firestore.collection('ministries').orderBy('name').limit(300).get();
      final names = snap.docs
          .map((d) => (d.data()['name'] ?? '').toString().trim())
          .where((n) => n.isNotEmpty)
          .toList();
      if (mounted) setState(() => _ministryOptions = ['All', ...names]);
    } catch (_) {
      if (mounted) setState(() => _ministryOptions = const ['All']);
    }
  }

  Future<void> _loadMoreMembers() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      Query q = _firestore.collection('members');
      if (_selectedMinistry != 'All') {
        q = q.where('ministries', arrayContains: _selectedMinistry);
      }
      if (_selectedGender != 'all') {
        q = q.where('genderBucket', isEqualTo: _selectedGender);
      }
      if (_selectedVisitor == 'visitor') {
        q = q.where('isVisitor', isEqualTo: true);
      } else if (_selectedVisitor == 'member') {
        q = q.where('isVisitor', isEqualTo: false);
      }
      q = q.orderBy('fullNameLower').limit(_pageSize);
      if (_lastMemberDoc != null) {
        q = q.startAfterDocument(_lastMemberDoc!);
      }
      final snap = await q.get();
      if (snap.docs.isNotEmpty) {
        _lastMemberDoc = snap.docs.last;
        _members.addAll(
          snap.docs.map((d) => {'id': d.id, ...(d.data() as Map<String, dynamic>)}),
        );
      }
      if (snap.docs.length < _pageSize) {
        _hasMore = false;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load members: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _applyFilters({
    String? ministry,
    String? gender,
    String? visitor,
  }) {
    setState(() {
      if (ministry != null) _selectedMinistry = ministry;
      if (gender != null) _selectedGender = gender;
      if (visitor != null) _selectedVisitor = visitor;
    });
    _searchResults.clear();
    _loadInitialMembers();
    if (_searchQuery.isNotEmpty) {
      _runSearch(_searchQuery);
    }
  }

  void _onSearchInput(String value) {
    final q = value.trim().toLowerCase();
    setState(() => _searchQuery = q);
    _searchDebounce?.cancel();
    if (q.length < 2) {
      setState(() {
        _searchResults.clear();
        _searchLoading = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      await _runSearch(q);
    });
  }

  Future<void> _runSearch(String q) async {
    setState(() => _searchLoading = true);
    try {
      final res = await MemberSearchService.searchMembers(
        q,
        limit: 100,
        ministryName: _selectedMinistry == 'All' ? null : _selectedMinistry,
        gender: _selectedGender,
        visitor: _selectedVisitor,
      );
      if (!mounted) return;
      setState(() {
        _searchResults
          ..clear()
          ..addAll(res);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searchResults.clear());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _searchLoading = false);
    }
  }

  Future<void> _submitAttendance() async {
    if (!attendanceStatus.containsValue(true)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("⚠️ Please mark at least one person present before submitting.")),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Confirm Attendance"),
        content: const Text("Do you want to submit today’s attendance? This will overwrite any previous check-ins."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text("Submit")),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _submitting = true);
    final window = _selectedWindow;
    final dateKey = window?.dateKey ?? _todayKey;
    final dateDocRef = _firestore.collection('attendance').doc(dateKey);
    final batch = _firestore.batch();

    batch.set(dateDocRef, {
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    }, SetOptions(merge: true));

    attendanceStatus.forEach((memberId, isPresent) {
      final docRef = dateDocRef.collection('records').doc(memberId);
      batch.set(docRef, {
        'memberId': memberId,
        'windowId': window?.id,
        'status': isPresent ? 'present' : 'absent',
        'present': isPresent,
        'checkedAt': Timestamp.now(),
        'by': 'manual',
      }, SetOptions(merge: true));
    });

    try {
      await batch.commit();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Attendance successfully recorded.")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("❌ Failed to submit attendance: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toggleStatus(String id, bool value) {
    setState(() => attendanceStatus[id] = value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Check-In'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: Column(
        children: [
          if (_loadingWindows)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_windows.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: DropdownButtonFormField<String>(
                value: _selectedWindowId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Service',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                items: _windows.map((w) {
                  final label = w.startsAt != null
                      ? '${w.title} — ${DateFormat('EEE, MMM d • h:mm a').format(w.startsAt!)}'
                      : w.title;
                  return DropdownMenuItem(value: w.id, child: Text(label));
                }).toList(),
                onChanged: (v) {
                  setState(() {
                    _selectedWindowId = v;
                    attendanceStatus = {};
                  });
                },
              ),
            ),
          // 🔍 Search bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: InputDecoration(
                hintText: "Search members...",
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onChanged: _onSearchInput,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              children: [
                Row(
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
                        onChanged: (v) => _applyFilters(ministry: v ?? 'All'),
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
                        onChanged: (v) => _applyFilters(gender: v ?? 'all'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _selectedVisitor,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Visitor Filter',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All')),
                    DropdownMenuItem(value: 'member', child: Text('Members')),
                    DropdownMenuItem(value: 'visitor', child: Text('Visitors')),
                  ],
                  onChanged: (v) => _applyFilters(visitor: v ?? 'all'),
                ),
              ],
            ),
          ),

          // 🧾 Members list (paged)
          Expanded(
            child: _loadingMembers && _members.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Loaded ${_members.length} members',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (_hasMore)
                              TextButton.icon(
                                onPressed: _loadingMore ? null : _loadMoreMembers,
                                icon: const Icon(Icons.add),
                                label: Text(_loadingMore ? 'Loading...' : 'Load more'),
                              )
                            else
                              const Text('All loaded'),
                          ],
                        ),
                      ),
                      if (_loadingMore)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      Expanded(
                        child: Builder(
                          builder: (context) {
                            final base = _searchQuery.isNotEmpty ? _searchResults : _members;
                            final filtered = base.where((m) {
                              final fullName =
                                  "${m['firstName'] ?? ''} ${m['lastName'] ?? ''}".toLowerCase();
                              return _searchQuery.isEmpty || fullName.contains(_searchQuery);
                            }).toList();

                            if (_searchQuery.isNotEmpty && _searchLoading) {
                              return const Center(child: CircularProgressIndicator());
                            }

                            if (filtered.isEmpty) {
                              return const Center(child: Text("No members found."));
                            }

                            return ListView.builder(
                              itemCount: filtered.length,
                              itemBuilder: (context, i) {
                                final data = filtered[i];
                                final fullName =
                                    "${data['firstName'] ?? ''} ${data['lastName'] ?? ''}".trim();
                                final id = (data['id'] ?? '').toString();
                                final isPresent = attendanceStatus[id] ?? false;

                                return Card(
                                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                  child: ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor:
                                          isPresent ? Colors.green : Colors.grey.shade400,
                                      child: Text(
                                        (data['firstName'] ?? "?")[0].toUpperCase(),
                                        style: const TextStyle(color: Colors.white),
                                      ),
                                    ),
                                    title: Text(fullName,
                                        style: const TextStyle(fontWeight: FontWeight.w600)),
                                    subtitle: Text(data['gender'] ?? "Member"),
                                    trailing: Switch(
                                      value: isPresent,
                                      onChanged: (val) => _toggleStatus(id, val),
                                      activeColor: Theme.of(context).colorScheme.primary,
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
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.teal,
        onPressed: _submitting ? null : _submitAttendance,
        icon: const Icon(Icons.check_circle_outline),
        label: Text(_submitting ? "Submitting..." : "Submit Attendance"),
      ),
    );
  }
}

class _AttendanceWindow {
  final String id;
  final String title;
  final String dateKey;
  final DateTime? startsAt;

  const _AttendanceWindow({
    required this.id,
    required this.title,
    required this.dateKey,
    required this.startsAt,
  });

  static _AttendanceWindow fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    final starts = data['startsAt'] as Timestamp?;
    return _AttendanceWindow(
      id: doc.id,
      title: (data['title'] ?? 'Service').toString(),
      dateKey: (data['dateKey'] ?? '').toString(),
      startsAt: starts?.toDate(),
    );
  }
}
