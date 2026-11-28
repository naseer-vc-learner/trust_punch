/// A piece of client work the company staffs: its locations, the activities
/// (jobs) done there, and the roles people are hired in.
///
/// Locations are [Site]s carrying this project's id; workers carry it too.
/// Jobs and roles are plain names kept here so every worker on the project
/// picks from the same list.
class Project {
  const Project({
    required this.id,
    required this.name,
    this.jobs = const [],
    this.roles = const [],
  });

  final String id;
  final String name;

  /// Activities, e.g. "Block A foundation", "MEP first fix".
  final List<String> jobs;

  /// Roles, e.g. "Mason", "Electrician", "Helper".
  final List<String> roles;

  Project copyWith({String? name, List<String>? jobs, List<String>? roles}) =>
      Project(
        id: id,
        name: name ?? this.name,
        jobs: jobs ?? this.jobs,
        roles: roles ?? this.roles,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'jobs': jobs, 'roles': roles};

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        id: json['id'] as String,
        name: json['name'] as String,
        jobs: [for (final j in (json['jobs'] as List? ?? const [])) '$j'],
        roles: [for (final r in (json['roles'] as List? ?? const [])) '$r'],
      );
}

/// The project that existing sites and workers are moved into the first time
/// the app runs with projects, so nothing recorded before is lost.
const generalProjectId = 'general';
