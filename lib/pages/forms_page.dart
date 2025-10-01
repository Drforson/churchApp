import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class FormsPage extends StatelessWidget {
  final _formKeys = {
    'Visitor Registration': GlobalKey<FormState>(),
    'Prayer Request': GlobalKey<FormState>(),
    'Baptism Interest': GlobalKey<FormState>(),
    'Volunteer Signup': GlobalKey<FormState>(),
  };

  final _controllers = {
    'name': TextEditingController(),
    'email': TextEditingController(),
    'message': TextEditingController(),
  };

  void _submitForm(BuildContext context, String formType) async {
    if (_formKeys[formType]!.currentState!.validate()) {
      await FirebaseFirestore.instance.collection('forms').add({
        'type': formType,
        'name': _controllers['name']!.text,
        'email': _controllers['email']!.text,
        'message': _controllers['message']!.text,
        'timestamp': Timestamp.now(),
      });

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$formType submitted')));
      _controllers.forEach((key, controller) => controller.clear());
    }
  }

  Widget _buildFormCard(BuildContext context, String title) {
    return Card(
      elevation: 3,
      margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: ExpansionTile(
        title: Text(title),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKeys[title],
              child: Column(
                children: [
                  TextFormField(
                    controller: _controllers['name'],
                    decoration: const InputDecoration(labelText: 'Name'),
                    validator: (value) => value!.isEmpty ? 'Enter your name' : null,
                  ),
                  TextFormField(
                    controller: _controllers['email'],
                    decoration: const InputDecoration(labelText: 'Email'),
                    validator: (value) => value!.isEmpty ? 'Enter your email' : null,
                  ),
                  TextFormField(
                    controller: _controllers['message'],
                    decoration: const InputDecoration(labelText: 'Message / Reason'),
                    maxLines: 3,
                    validator: (value) => value!.isEmpty ? 'Enter your message' : null,
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: () => _submitForm(context, title),
                    child: const Text('Submit'),
                  )
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final formTitles = _formKeys.keys.toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Forms & Sign-Ups')),
      body: ListView(
        children: formTitles.map((title) => _buildFormCard(context, title)).toList(),
      ),
    );
  }
}
