import 'dart:math' as math;

/// A day is a sequence of these, per worker: in → (break out/in)* → out.
enum PunchType { checkIn, breakStart, breakEnd, checkOut }

/// Where a worker stands right now. Decides which punches are legal next.
enum WorkerStatus { off, working, onBreak }

/// A worker's place on one project: their role there and their job
/// (activity).
class ProjectAssignment {
  const ProjectAssignment({
    required this.projectId,
    this.role = '',
    this.job = '',
  });

  final String projectId;
  final String role;
  final String job;

  Map<String, dynamic> toJson() =>
      {'projectId': projectId, 'role': role, 'job': job};

  factory ProjectAssignment.fromJson(Map<String, dynamic> json) =>
      ProjectAssignment(
        projectId: json['projectId'] as String,
        role: json['role'] as String? ?? '',
        job: json['job'] as String? ?? '',
      );
}

class Worker {
  const Worker({
    required this.id,
    required this.employeeId,
    required this.name,
    required this.embeddings,
    this.projectId = '',
    this.role = '',
    this.job = '',
    this.otherProjects = const [],
  });

  final String id;

  /// The number written on the badge — what payroll and the supervisor use.
  /// Distinct from [id], which is internal and never shown.
  final String employeeId;
  final String name;

  /// One face embedding per enrolled angle.
  final List<List<double>> embeddings;

  /// The worker's first project, with their [role] and [job] there. They can
  /// punch at the locations of this and [otherProjects], nowhere else.
  final String projectId;

  /// Their role on [projectId] (e.g. Mason) and current job/activity.
  final String role;
  final String job;

  /// Further projects, each with its own role and job.
  final List<ProjectAssignment> otherProjects;

  /// Every project this worker is on, first project first.
  List<ProjectAssignment> get assignments => [
        if (projectId.isNotEmpty)
          ProjectAssignment(projectId: projectId, role: role, job: job),
        ...otherProjects,
      ];

  bool isOn(String project) =>
      project.isNotEmpty &&
      (projectId == project || otherProjects.any((a) => a.projectId == project));

  /// Role and job on [project]; null when not on it.
  ProjectAssignment? assignmentIn(String project) {
    for (final a in assignments) {
      if (a.projectId == project) return a;
    }
    return null;
  }

  /// Puts the worker on [project] with this role and job, or changes them
  /// there. Other projects stay as they are.
  Worker withAssignment(String project, {String role = '', String job = ''}) {
    if (projectId.isEmpty || projectId == project) {
      return copyWith(projectId: project, role: role, job: job);
    }
    final updated = ProjectAssignment(projectId: project, role: role, job: job);
    final i = otherProjects.indexWhere((a) => a.projectId == project);
    return copyWith(
      otherProjects: [
        for (final a in otherProjects) a.projectId == project ? updated : a,
        if (i < 0) updated,
      ],
    );
  }

  /// Takes the worker off [project]. Null when it is their only project: a
  /// worker on no project could not punch anywhere.
  Worker? withoutProject(String project) {
    if (!isOn(project) || assignments.length == 1) return null;
    if (projectId != project) {
      return copyWith(
        otherProjects: [
          for (final a in otherProjects)
            if (a.projectId != project) a,
        ],
      );
    }
    final next = otherProjects.first;
    return copyWith(
      projectId: next.projectId,
      role: next.role,
      job: next.job,
      otherProjects: otherProjects.sublist(1),
    );
  }

  Worker copyWith({
    String? projectId,
    String? role,
    String? job,
    List<ProjectAssignment>? otherProjects,
  }) =>
      Worker(
        id: id,
        employeeId: employeeId,
        name: name,
        embeddings: embeddings,
        projectId: projectId ?? this.projectId,
        role: role ?? this.role,
        job: job ?? this.job,
        otherProjects: otherProjects ?? this.otherProjects,
      );

  /// Highest similarity against any enrolled angle of this worker.
  double bestSimilarity(List<double> candidate) {
    var best = -1.0;
    for (final enrolled in embeddings) {
      final score = cosineSimilarity(enrolled, candidate);
      if (score > best) best = score;
    }
    return best;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'employeeId': employeeId,
        'name': name,
        'embeddings': embeddings,
        'projectId': projectId,
        'role': role,
        'job': job,
        if (otherProjects.isNotEmpty)
          'otherProjects': [for (final a in otherProjects) a.toJson()],
      };

  factory Worker.fromJson(Map<String, dynamic> json) => Worker(
        id: json['id'] as String,
        employeeId: json['employeeId'] as String? ?? '',
        name: json['name'] as String,
        embeddings: (json['embeddings'] as List)
            .map((e) => (e as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
        projectId: json['projectId'] as String? ?? '',
        role: json['role'] as String? ?? '',
        job: json['job'] as String? ?? '',
        otherProjects: [
          for (final a in json['otherProjects'] as List? ?? const [])
            ProjectAssignment.fromJson(a as Map<String, dynamic>),
        ],
      );
}

/// A location of a project: where people check in, and when its shift runs.
class Site {
  const Site({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    this.projectId = '',
    this.shiftStartMinutes = defaultShiftStart,
    this.shiftEndMinutes = defaultShiftEnd,
  });

  /// 09:00–17:00, the single shift the app had before locations had their own.
  static const defaultShiftStart = 9 * 60;
  static const defaultShiftEnd = 17 * 60;

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final String projectId;

  /// Shift start and end, as minutes after midnight (e.g. 450 = 07:30).
  final int shiftStartMinutes;
  final int shiftEndMinutes;

  /// This location's shift start on [day].
  DateTime shiftStartOn(DateTime day) =>
      DateTime(day.year, day.month, day.day).add(Duration(minutes: shiftStartMinutes));

  /// This location's shift end on [day].
  DateTime shiftEndOn(DateTime day) =>
      DateTime(day.year, day.month, day.day).add(Duration(minutes: shiftEndMinutes));

  Site copyWith({
    String? name,
    String? projectId,
    int? shiftStartMinutes,
    int? shiftEndMinutes,
  }) =>
      Site(
        id: id,
        name: name ?? this.name,
        latitude: latitude,
        longitude: longitude,
        projectId: projectId ?? this.projectId,
        shiftStartMinutes: shiftStartMinutes ?? this.shiftStartMinutes,
        shiftEndMinutes: shiftEndMinutes ?? this.shiftEndMinutes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': latitude,
        'lng': longitude,
        'projectId': projectId,
        'shiftStart': shiftStartMinutes,
        'shiftEnd': shiftEndMinutes,
      };

  factory Site.fromJson(Map<String, dynamic> json) => Site(
        id: json['id'] as String,
        name: json['name'] as String,
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
        projectId: json['projectId'] as String? ?? '',
        shiftStartMinutes:
            (json['shiftStart'] as num?)?.toInt() ?? defaultShiftStart,
        shiftEndMinutes: (json['shiftEnd'] as num?)?.toInt() ?? defaultShiftEnd,
      );
}

/// "07:30" for 450 minutes after midnight.
String formatShiftTime(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

class Punch {
  const Punch({
    required this.type,
    required this.at,
    required this.workerId,
    required this.employeeId,
    required this.workerName,
    required this.siteId,
    required this.siteName,
    required this.latitude,
    required this.longitude,
    required this.distanceMeters,
    this.auto = false,
    this.photo,
    this.corrected = false,
    this.clockSuspect = false,
  });

  /// Added by a supervisor-approved correction, not punched live.
  final bool corrected;

  /// The phone's clock disagreed with the GPS time by more than a few
  /// minutes when this punch was made: worth a supervisor's look.
  final bool clockSuspect;

  /// File name of the small selfie taken at this punch, kept by
  /// `PunchPhotoStore`. Null for automatic punches and older records.
  final String? photo;

  /// Added by the app, not punched by the worker: a session left open at
  /// another location (or on an earlier day) closed when they checked in.
  final bool auto;

  final PunchType type;
  final DateTime at;
  final String workerId;
  final String employeeId;
  final String workerName;
  final String siteId;
  final String siteName;
  final double latitude;
  final double longitude;
  final double distanceMeters;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'at': at.toIso8601String(),
        'workerId': workerId,
        'employeeId': employeeId,
        'workerName': workerName,
        'siteId': siteId,
        'siteName': siteName,
        'lat': latitude,
        'lng': longitude,
        'distance': distanceMeters,
        if (auto) 'auto': true,
        if (photo != null) 'photo': photo,
        if (corrected) 'corrected': true,
        if (clockSuspect) 'clockSuspect': true,
      };

  factory Punch.fromJson(Map<String, dynamic> json) => Punch(
        type: PunchType.values.byName(json['type'] as String),
        at: DateTime.parse(json['at'] as String),
        workerId: json['workerId'] as String? ?? '',
        employeeId: json['employeeId'] as String? ?? '',
        workerName: json['workerName'] as String? ?? '',
        siteId: json['siteId'] as String? ?? '',
        siteName: json['siteName'] as String? ?? 'Unknown',
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
        distanceMeters: (json['distance'] as num).toDouble(),
        auto: json['auto'] as bool? ?? false,
        photo: json['photo'] as String?,
        corrected: json['corrected'] as bool? ?? false,
        clockSuspect: json['clockSuspect'] as bool? ?? false,
      );
}

double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return -1;
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA == 0 || normB == 0) return -1;
  return dot / (math.sqrt(normA) * math.sqrt(normB));
}
