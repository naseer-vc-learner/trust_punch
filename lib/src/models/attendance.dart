import 'dart:math' as math;

/// A day is a sequence of these, per worker: in → (break out/in)* → out.
enum PunchType { checkIn, breakStart, breakEnd, checkOut }

/// Where a worker stands right now. Decides which punches are legal next.
enum WorkerStatus { off, working, onBreak }

class Worker {
  const Worker({
    required this.id,
    required this.employeeId,
    required this.name,
    required this.embeddings,
    this.projectId = '',
    this.role = '',
    this.job = '',
  });

  final String id;

  /// The number written on the badge — what payroll and the supervisor use.
  /// Distinct from [id], which is internal and never shown.
  final String employeeId;
  final String name;

  /// One face embedding per enrolled angle.
  final List<List<double>> embeddings;

  /// The project this worker is on. They can punch at any of its locations
  /// and none of anyone else's.
  final String projectId;

  /// Their role on the project (e.g. Mason) and current job/activity.
  final String role;
  final String job;

  Worker copyWith({String? projectId, String? role, String? job}) => Worker(
        id: id,
        employeeId: employeeId,
        name: name,
        embeddings: embeddings,
        projectId: projectId ?? this.projectId,
        role: role ?? this.role,
        job: job ?? this.job,
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
  });

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
