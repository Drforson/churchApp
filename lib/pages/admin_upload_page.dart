import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class AdminUploadPage extends StatefulWidget {
  const AdminUploadPage({super.key});

  @override
  State<AdminUploadPage> createState() => _AdminUploadPageState();
}

class _AdminUploadPageState extends State<AdminUploadPage> {
  final _sermonTitleController = TextEditingController();
  final _sermonThumbnailController = TextEditingController();
  final _sermonVideoUrlController = TextEditingController();
  DateTime? _sermonDate;

  final _eventTitleController = TextEditingController();
  final _eventImageUrlController = TextEditingController();
  DateTime? _eventStartDate;
  DateTime? _eventEndDate;
  bool _showRSVP = false;

  final _formKey = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text('Upload Content', style: Theme.of(context).textTheme.bodyLarge),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE0EAFC), Color(0xFFCFDEF3)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle('Upload Sermon'),
                _buildTextField(_sermonTitleController, 'Sermon Title'),
                _buildTextField(_sermonThumbnailController, 'Thumbnail URL'),
                _buildTextField(_sermonVideoUrlController, 'Video URL'),
                _buildDatePicker('Sermon Date', _sermonDate, (date) => setState(() => _sermonDate = date)),
                const SizedBox(height: 10),
                _buildSubmitButton('Upload Sermon', _uploadSermon),

                const SizedBox(height: 40),
                _sectionTitle('Upload Event'),
                _buildTextField(_eventTitleController, 'Event Title'),
                _buildTextField(_eventImageUrlController, 'Layer Image URL'),
                _buildDatePicker('Start Date', _eventStartDate, (date) => setState(() => _eventStartDate = date)),
                _buildDatePicker('End Date', _eventEndDate, (date) => setState(() => _eventEndDate = date)),
                Row(
                  children: [
                    Checkbox(
                      value: _showRSVP,
                      onChanged: (val) => setState(() => _showRSVP = val ?? false),
                    ),
                    Text('Enable RSVP', style: Theme.of(context).textTheme.bodyLarge),
                  ],
                ),
                _buildSubmitButton('Upload Event', _uploadEvent),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );
  }

  Widget _buildTextField(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        validator: (val) => val == null || val.isEmpty ? 'Required' : null,
      ),
    );
  }

  Widget _buildDatePicker(String label, DateTime? date, ValueChanged<DateTime?> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              date == null
                  ? '$label: Not selected'
                  : '$label: ${date.toLocal().toString().split(' ')[0]}',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime(2100),
              );
              if (picked != null) onChanged(picked);
            },
            child: const Text('Pick Date'),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton(String label, VoidCallback onPressed) {
    return Center(
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.upload),
        label: Text(label, style: Theme.of(context).textTheme.bodyLarge),
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  void _uploadSermon() async {
    if (!_formKey.currentState!.validate() || _sermonDate == null) return;

    await FirebaseFirestore.instance.collection('sermons').add({
      'title': _sermonTitleController.text,
      'thumbnailUrl': _sermonThumbnailController.text,
      'videoUrl': _sermonVideoUrlController.text,
      'date': _sermonDate,
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Sermon uploaded', style: Theme.of(context).textTheme.bodyLarge)),
    );
  }

  void _uploadEvent() async {
    if (!_formKey.currentState!.validate() || _eventStartDate == null) return;

    await FirebaseFirestore.instance.collection('events').add({
      'title': _eventTitleController.text,
      'imageUrl': _eventImageUrlController.text,
      'startDate': _eventStartDate,
      'endDate': _eventEndDate,
      'showRSVP': _showRSVP,
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Event uploaded', style: Theme.of(context).textTheme.bodyLarge)),
    );
  }
}
