import 'package:cloud_firestore/cloud_firestore.dart';

class MinistryModel {
  final String id;
  final String name;
  final String description;
  final List<String> leaderIds;
  final String createdBy;
  final bool approved;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  MinistryModel({
    required this.id,
    required this.name,
    required this.description,
    this.leaderIds = const [],
    this.createdBy = '',
    this.approved = true, // legacy docs treated as approved
    this.createdAt,
    this.updatedAt,
  });

  static DateTime? _toDateTime(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  factory MinistryModel.fromMap(String id, Map<String, dynamic> data) {
    return MinistryModel(
      id: id,
      name: (data['name'] ?? '') as String,
      description: (data['description'] ?? '') as String,
      leaderIds: List<String>.from(data['leaderIds'] ?? const <String>[]),
      createdBy: (data['createdBy'] ?? '') as String,
      approved: data['approved'] is bool ? (data['approved'] as bool) : true,
      createdAt: _toDateTime(data['createdAt']),
      updatedAt: _toDateTime(data['updatedAt']),
    );
  }

  factory MinistryModel.fromDocument(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>? ?? const {});
    return MinistryModel.fromMap(doc.id, data);
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'leaderIds': leaderIds,
      'createdBy': createdBy,
      'approved': approved,
      if (createdAt != null) 'createdAt': Timestamp.fromDate(createdAt!),
      if (updatedAt != null) 'updatedAt': Timestamp.fromDate(updatedAt!),
    };
  }

  MinistryModel copyWith({
    String? id,
    String? name,
    String? description,
    List<String>? leaderIds,
    String? createdBy,
    bool? approved,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return MinistryModel(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      leaderIds: leaderIds ?? this.leaderIds,
      createdBy: createdBy ?? this.createdBy,
      approved: approved ?? this.approved,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
