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
  });

  final String id;

  /// The number written on the badge — what payroll and the supervisor use.
  /// Distinct from [id], which is internal and never shown.
  final String employeeId;
  final String name;

  /// One face embedding per enrolled angle.
  final List<List<double>> embeddings;

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
      };

  factory Worker.fromJson(Map<String, dynamic> json) => Worker(
        id: json['id'] as String,
        employeeId: json['employeeId'] as String? ?? '',
        name: json['name'] as String,
        embeddings: (json['embeddings'] as List)
            .map((e) => (e as List).map((v) => (v as num).toDouble()).toList())
            .toList(),
      );
}

class Site {
  const Site({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'lat': latitude, 'lng': longitude};

  factory Site.fromJson(Map<String, dynamic> json) => Site(
        id: json['id'] as String,
        name: json['name'] as String,
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
      );
}

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
  });

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
