import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

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

  String get _todayKey {
    final now = DateTime.now();
    return DateFormat('yyyy-MM-dd').format(now);
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
    final dateDocRef = _firestore.collection('attendance').doc(_todayKey);
    final batch = _firestore.batch();

    batch.set(dateDocRef, {
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    }, SetOptions(merge: true));

    attendanceStatus.forEach((memberId, isPresent) {
      final docRef = dateDocRef.collection('records').doc(memberId);
      batch.set(docRef, {
        'memberId': memberId,
        'present': isPresent,
        'timestamp': Timestamp.now(),
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
        backgroundColor: Colors.teal.shade600,
        foregroundColor: Colors.white,
        centerTitle: true,
      ),
      body: Column(
        children: [
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
              onChanged: (q) => setState(() => _searchQuery = q.toLowerCase()),
            ),
          ),

          // 🧾 Members list (live updates)
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _firestore.collection('members').orderBy('firstName').snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

                final members = snapshot.data!.docs;
                final filtered = members.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final fullName = "${data['firstName'] ?? ''} ${data['lastName'] ?? ''}".toLowerCase();
                  return fullName.contains(_searchQuery);
                }).toList();

                if (filtered.isEmpty) {
                  return const Center(child: Text("No members found."));
                }

                return ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, i) {
                    final doc = filtered[i];
                    final data = doc.data() as Map<String, dynamic>;
                    final fullName = "${data['firstName'] ?? ''} ${data['lastName'] ?? ''}".trim();
                    final id = doc.id;
                    final isPresent = attendanceStatus[id] ?? false;

                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isPresent ? Colors.green : Colors.grey.shade400,
                          child: Text(
                            (data['firstName'] ?? "?")[0].toUpperCase(),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(data['gender'] ?? "Member"),
                        trailing: Switch(
                          value: isPresent,
                          onChanged: (val) => _toggleStatus(id, val),
                          activeColor: Colors.teal,
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
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.teal,
        onPressed: _submitting ? null : _submitAttendance,
        icon: const Icon(Icons.check_circle_outline),
        label: Text(_submitting ? "Submitting..." : "Submit Attendance"),
      ),
    );
  }
}
