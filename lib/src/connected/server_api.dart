import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Where the TrustPunch server is, if anywhere.
///
/// Empty by default: the connected app then makes no network call at all.
/// A development run turns it on with
/// `--dart-define=API_BASE_URL=https://192.168.x.x:8443`.
const apiBaseUrl = String.fromEnvironment('API_BASE_URL');

/// The development CA certificate (PEM, base64-encoded), passed only on
/// development runs with `--dart-define=API_DEV_CA=$(base64 -i dev-ca.pem)`.
///
/// When present, the app trusts this CA and nothing else (the phone's normal
/// trusted CAs are switched off), which pins it to the Mac's own server.
/// It is never compiled into a build unless someone passes it.
const _devCaBase64 = String.fromEnvironment('API_DEV_CA');

bool get serverConfigured => apiBaseUrl.isNotEmpty;

class ServerHealth {
  const ServerHealth._({
    required this.ok,
    this.version,
    this.roundTrip,
    this.clockDifference,
    this.error,
  });

  factory ServerHealth.failed(String error) =>
      ServerHealth._(ok: false, error: error);

  final bool ok;
  final String? version;
  final Duration? roundTrip;

  /// The phone's clock minus the server's.
  final Duration? clockDifference;
  final String? error;
}

/// Why a request did not succeed.
enum ServerProblem {
  /// No answer: off, not on this Wi-Fi, or the certificate is not trusted.
  unreachable,

  /// The phone is not (or no longer) paired: pair again.
  notPaired,

  /// The server's operator blocked this phone, or the pairing code was wrong.
  refused,

  /// Too many wrong pairing codes: wait, and ask for a new one.
  tooManyAttempts,

  /// The server could not read what was sent (a bug, never retried as is).
  invalid,

  /// Anything else the server said.
  other,
}

class ServerException implements Exception {
  const ServerException(this.problem, this.message);

  final ServerProblem problem;
  final String message;

  @override
  String toString() => message;
}

/// What the server did with an upload.
class UploadResult {
  const UploadResult({
    required this.accepted,
    required this.duplicates,
    required this.rejected,
    required this.flags,
  });

  /// Stored now.
  final List<String> accepted;

  /// Already stored before (a resend): done too.
  final List<String> duplicates;

  /// Never stored: id → reason. Not sent again.
  final Map<String, String> rejected;

  /// The server's own findings for accepted punches: id → flags.
  final Map<String, List<String>> flags;
}

class ServerApi {
  ServerApi({required this.baseUrl, this.trustedCaPem}) {
    _checkTransport(baseUrl);
  }

  /// Built from the run's `--dart-define`s; null when no server is set.
  static ServerApi? fromEnvironment() {
    if (!serverConfigured) return null;
    return ServerApi(
      baseUrl: Uri.parse(apiBaseUrl),
      trustedCaPem: _devCaBase64.isEmpty ? null : base64Decode(_devCaBase64),
    );
  }

  final Uri baseUrl;

  /// The only CA trusted when set; the phone's usual CAs when null.
  final List<int>? trustedCaPem;

  static const _timeout = Duration(seconds: 10);

  /// HTTPS only. Plain HTTP is allowed to this phone itself (loopback), which
  /// tests use, and nowhere else — attendance data never crosses a network
  /// unencrypted.
  static void _checkTransport(Uri url) {
    if (url.scheme == 'https') return;
    final loopback = url.host == 'localhost' ||
        (InternetAddress.tryParse(url.host)?.isLoopback ?? false);
    if (url.scheme == 'http' && loopback) return;
    throw ArgumentError('Server address must use https: $url');
  }

  HttpClient _client() {
    final ca = trustedCaPem;
    final context = ca == null
        ? SecurityContext(withTrustedRoots: true)
        : (SecurityContext(withTrustedRoots: false)
          ..setTrustedCertificatesBytes(ca));
    return HttpClient(context: context)..connectionTimeout = _timeout;
  }

  /// One JSON request. Throws [ServerException], never anything else.
  Future<(int, Map<String, dynamic>)> _request(
    String method,
    String path, {
    String? token,
    Object? body,
    Map<String, String>? query,
    Duration timeout = _timeout,
  }) async {
    final client = _client()..connectionTimeout = timeout;
    try {
      var url = baseUrl.resolve(path);
      if (query != null) url = url.replace(queryParameters: query);
      final request = await client.openUrl(method, url).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join();
      final json = text.isEmpty
          ? const <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>;
      return (response.statusCode, json);
    } on HandshakeException {
      throw const ServerException(
          ServerProblem.unreachable, 'Certificate not trusted');
    } on TimeoutException {
      throw const ServerException(ServerProblem.unreachable, 'No answer');
    } on IOException {
      // Socket and HTTP errors when the server or the Wi-Fi goes away.
      throw const ServerException(ServerProblem.unreachable, 'Not reachable');
    } on OSError {
      // "Connection reset by peer" arrives as a bare OSError, which is not
      // an IOException: a server restarting mid-request.
      throw const ServerException(ServerProblem.unreachable, 'Not reachable');
    } on FormatException {
      throw const ServerException(ServerProblem.other, 'Unexpected answer');
    } finally {
      client.close(force: true);
    }
  }

  static Never _fail(int status, Map<String, dynamic> body) {
    final detail = '${body['detail'] ?? 'HTTP $status'}';
    throw ServerException(
      switch (status) {
        401 => ServerProblem.notPaired,
        403 => ServerProblem.refused,
        429 => ServerProblem.tooManyAttempts,
        422 => ServerProblem.invalid,
        _ => ServerProblem.other,
      },
      detail,
    );
  }

  /// Asks the server whether it is up. Never throws: a server that cannot be
  /// reached is a normal state for an offline-first app.
  Future<ServerHealth> health() async {
    final stopwatch = Stopwatch()..start();
    try {
      final (status, json) = await _request('GET', '/health');
      stopwatch.stop();
      if (status != 200) return ServerHealth.failed('HTTP $status');
      if (json['status'] != 'ok') return ServerHealth.failed('Not ready');
      final serverTime = DateTime.tryParse('${json['serverTime']}');
      return ServerHealth._(
        ok: true,
        version: json['version'] as String?,
        roundTrip: stopwatch.elapsed,
        clockDifference: serverTime == null
            ? null
            : DateTime.now().toUtc().difference(serverTime.toUtc()),
      );
    } on ServerException catch (e) {
      return ServerHealth.failed(e.message);
    }
  }

  /// Trades a one-time code from the server's operator for this phone's
  /// token. Returns (deviceId, token).
  Future<(String, String)> pair({
    required String code,
    required String deviceName,
    required String platform,
  }) async {
    final (status, json) = await _request('POST', '/devices/pair', body: {
      'code': code,
      'deviceName': deviceName,
      'platform': platform,
    });
    if (status != 200) _fail(status, json);
    return (json['deviceId'] as String, json['token'] as String);
  }

  /// Whether [workerId] is checked in right now according to the server,
  /// and whether on this phone. [day] is the phone's local date. Short
  /// timeout: a worker is standing at the phone waiting.
  Future<({bool open, bool onThisPhone})> openSession(
    String token,
    String workerId,
    DateTime day,
  ) async {
    final date = '${day.year.toString().padLeft(4, '0')}-'
        '${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
    final (status, json) = await _request(
      'GET',
      '/workers/${Uri.encodeComponent(workerId)}/open-session',
      token: token,
      query: {'day': date},
      timeout: const Duration(seconds: 3),
    );
    if (status != 200) _fail(status, json);
    return (
      open: json['open'] == true,
      onThisPhone: json['onThisPhone'] == true,
    );
  }

  /// Sends punches (already in the server's JSON shape). [sentAt] is the
  /// phone's clock now, which the server compares with its own.
  Future<UploadResult> uploadPunches(
    String token,
    List<Map<String, dynamic>> punches, {
    DateTime? sentAt,
  }) async {
    final (status, json) = await _request(
      'POST',
      '/punches/batch',
      token: token,
      body: {
        'sentAt': (sentAt ?? DateTime.now()).toUtc().toIso8601String(),
        'punches': punches,
      },
    );
    if (status != 200) _fail(status, json);
    List<String> ids(Object? v) => [for (final e in v as List? ?? []) '$e'];
    return UploadResult(
      accepted: ids(json['accepted']),
      duplicates: ids(json['duplicates']),
      rejected: {
        for (final r in json['rejected'] as List? ?? [])
          '${(r as Map)['id']}': '${r['reason']}',
      },
      flags: {
        for (final e in (json['flags'] as Map? ?? {}).entries)
          '${e.key}': ids(e.value),
      },
    );
  }
}
