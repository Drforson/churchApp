import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class PostAnnouncementsPage extends StatefulWidget {
  const PostAnnouncementsPage({super.key});

  @override
  State<PostAnnouncementsPage> createState() => _PostAnnouncementsPageState();
}

class _PostAnnouncementsPageState extends State<PostAnnouncementsPage> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _bodyController = TextEditingController();

  Future<void> _submitAnnouncement() async {
    if (!_formKey.currentState!.validate()) return;

    await FirebaseFirestore.instance.collection('announcements').add({
      'title': _titleController.text.trim(),
      'body': _bodyController.text.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    });

    _titleController.clear();
    _bodyController.clear();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Announcement posted!', style: Theme.of(context).textTheme.bodyLarge)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Post Announcement', style: Theme.of(context).textTheme.bodyLarge),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Title'),
                validator: (val) => val == null || val.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _bodyController,
                decoration: const InputDecoration(labelText: 'Body'),
                maxLines: 5,
                validator: (val) => val == null || val.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _submitAnnouncement,
                icon: const Icon(Icons.send),
                label: Text('Post', style: Theme.of(context).textTheme.bodyLarge),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
