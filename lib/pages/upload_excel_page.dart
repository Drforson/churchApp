// 📦 Dependencies:
//   excel: ^2.0.0
//   file_picker: ^5.2.5
//   cloud_firestore: ^4.8.0
//   intl: ^0.18.1
//   uuid: ^3.0.7   <-- ✅ For invitation code generation

import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

class ExcelDatabaseUploader extends StatefulWidget {
  const ExcelDatabaseUploader({super.key});

  @override
  State<ExcelDatabaseUploader> createState() => _ExcelDatabaseUploaderState();
}

class _ExcelDatabaseUploaderState extends State<ExcelDatabaseUploader> {
  bool _uploading = false;
  String _statusMessage = 'Select an Excel file to upload';

  final _uuid = Uuid(); // 🆕 For invitation codes

  DateTime? _standardizeDate(dynamic cellValue) {
    if (cellValue == null) return null;
    if (cellValue is num) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(((cellValue - 25569).toInt() * 86400000));
      } catch (_) {}
    }
    final List<DateFormat> formats = [
      DateFormat('dd/MM/yyyy'),
      DateFormat('MM/dd/yyyy'),
      DateFormat('yyyy-MM-dd')
    ];
    for (var format in formats) {
      try {
        return format.parseStrict(cellValue.toString().trim());
      } catch (_) {}
    }
    return null;
  }

  Future<void> _pickAndUploadExcelFile() async {
    setState(() {
      _uploading = true;
      _statusMessage = 'Picking file...';
    });

    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx']);
    if (result == null || result.files.single.path == null) {
      setState(() {
        _uploading = false;
        _statusMessage = 'File picking cancelled.';
      });
      return;
    }

    File file = File(result.files.single.path!);
    final bytes = await file.readAsBytes();
    final excel = Excel.decodeBytes(bytes);

    final sheet = excel['Form responses 1'];

    final membersCollection = FirebaseFirestore.instance.collection('members');
    final ministriesCollection = FirebaseFirestore.instance.collection('ministries');

    int newMembersCount = 0;
    Set<String> newMinistries = {};

    for (var row in sheet.rows.skip(1)) {
      if (row[2] == null || row[3] == null) continue;

      String firstName = row[2]?.value.toString().trim() ?? '';
      String lastName = row[3]?.value.toString().trim() ?? '';
      String email = row[1]?.value.toString().trim() ?? '';
      String phoneNumber = row[4]?.value.toString().trim() ?? '';
      String gender = row[13]?.value.toString().trim() ?? '';
      String ministriesStr = row[8]?.value.toString().trim() ?? '';
      List<String> ministries = ministriesStr.split(',').map((m) => m.trim()).where((m) => m.isNotEmpty).toList();
      DateTime? dob = _standardizeDate(row[5]?.value);
      DateTime? createdAt = _standardizeDate(row[0]?.value);

      final existingMember = await membersCollection.where('email', isEqualTo: email).limit(1).get();
      if (existingMember.docs.isEmpty) {
        try {
          // 🆕 Generate a Unique Invitation Code
          String invitationCode = _uuid.v4().substring(0, 6).toUpperCase(); // Example: "A1B2C3"

          await membersCollection.add({
            'firstName': firstName,
            'lastName': lastName,
            'email': email,
            'phoneNumber': phoneNumber,
            'dateOfBirth': dob != null ? Timestamp.fromDate(dob) : null,
            'gender': gender,
            'ministries': ministries,
            'ministryLeaderships': [],
            'userRole': 'member',
            'isInvited': true,
            'usedInvitation': false,
            'invitationCode': invitationCode,
            'createdAt': createdAt != null ? Timestamp.fromDate(createdAt) : FieldValue.serverTimestamp(),
          });
          newMembersCount++;
        } catch (e) {
        }
      }

      for (String ministry in ministries) {
        String fullName = "$firstName $lastName";
        DocumentReference ministryDoc = ministriesCollection.doc(ministry.replaceAll(' ', '_'));
        DocumentSnapshot docSnapshot = await ministryDoc.get();

        if (!docSnapshot.exists) {
          await ministryDoc.set({
            'name': ministry,
            'members': [fullName],
            'createdAt': createdAt != null ? Timestamp.fromDate(createdAt) : FieldValue.serverTimestamp(),
          });
          newMinistries.add(ministry);
        } else {
          List<dynamic> existingMembers = docSnapshot.get('members') ?? [];
          if (!existingMembers.contains(fullName)) {
            existingMembers.add(fullName);
            await ministryDoc.update({
              'members': existingMembers,
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }
        }
      }
    }

    setState(() {
      _uploading = false;
      _statusMessage = 'Upload complete!\nNew Members: $newMembersCount\nNew Ministries: ${newMinistries.length}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Excel Database Uploader")),
      body: Center(
        child: _uploading
            ? const CircularProgressIndicator()
            : Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _pickAndUploadExcelFile,
              child: const Text("Upload Excel File"),
            ),
            const SizedBox(height: 20),
            Text(_statusMessage),
          ],
        ),
      ),
    );
  }
}
