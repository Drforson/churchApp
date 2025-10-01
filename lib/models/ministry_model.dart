class MinistryModel {
  final String id;
  final String name;
  final String description;
  final List<String> leaderIds;
  final String createdBy;

  MinistryModel({
    required this.id,
    required this.name,
    required this.description,
    this.leaderIds = const [],
    this.createdBy = '',
  });

  factory MinistryModel.fromMap(String id, Map<String, dynamic> data) {
    return MinistryModel(
      id: id,
      name: data['name'] ?? '',
      description: data['description'] ?? '',
      leaderIds: List<String>.from(data['leaderIds'] ?? []),
      createdBy: data['createdBy'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'leaderIds': leaderIds,
      'createdBy': createdBy,
    };
  }
}
