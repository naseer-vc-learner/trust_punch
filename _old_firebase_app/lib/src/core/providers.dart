import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/repositories/attendance_repository.dart';
import '../data/services/device_service.dart';
import '../data/services/location_service.dart';
import '../data/services/offline_queue.dart';
import '../data/services/trustpunch_api.dart';

/// Composition root. Every dependency is overridable, which is what lets the
/// widget tests run the real screens against fakes instead of live Firebase.

final firebaseAuthProvider = Provider<FirebaseAuth>((_) => FirebaseAuth.instance);

final firestoreProvider =
    Provider<FirebaseFirestore>((_) => FirebaseFirestore.instance);

final apiProvider = Provider<TrustPunchApi>((_) => TrustPunchApi());

final deviceServiceProvider = Provider<DeviceService>((_) => DeviceService());

final locationServiceProvider = Provider<LocationService>((_) => LocationService());

final offlineQueueProvider = Provider<OfflineQueue>((_) => OfflineQueue());

final attendanceRepositoryProvider = Provider<AttendanceRepository>((ref) {
  return AttendanceRepository(
    api: ref.watch(apiProvider),
    devices: ref.watch(deviceServiceProvider),
    location: ref.watch(locationServiceProvider),
    queue: ref.watch(offlineQueueProvider),
    firestore: ref.watch(firestoreProvider),
  );
});

final authStateProvider = StreamProvider<User?>(
  (ref) => ref.watch(firebaseAuthProvider).authStateChanges(),
);

final currentEmployeeIdProvider = Provider<String?>(
  (ref) => ref.watch(authStateProvider).valueOrNull?.uid,
);

final currentEmployeeProvider = StreamProvider<Employee?>((ref) {
  final id = ref.watch(currentEmployeeIdProvider);
  if (id == null) return Stream.value(null);
  return ref.watch(attendanceRepositoryProvider).employee(id);
});

/// The employee's open working day, or null when not checked in.
final openSessionProvider = StreamProvider<WorkSession?>((ref) {
  final id = ref.watch(currentEmployeeIdProvider);
  if (id == null) return Stream.value(null);
  return ref.watch(attendanceRepositoryProvider).openSession(id);
});

final myAttendanceProvider = StreamProvider<List<AttendanceRecord>>((ref) {
  final id = ref.watch(currentEmployeeIdProvider);
  if (id == null) return Stream.value(const []);
  return ref.watch(attendanceRepositoryProvider).myRecords(id);
});

final assignedSitesProvider = FutureProvider<List<Site>>((ref) async {
  final employee = ref.watch(currentEmployeeProvider).valueOrNull;
  if (employee == null) return const [];
  return ref.watch(attendanceRepositoryProvider).sites(employee.assignedSiteIds);
});

/// Root/jailbreak posture, re-read on each app start.
final deviceIntegrityProvider = FutureProvider<DeviceIntegrity>(
  (ref) => ref.watch(deviceServiceProvider).integrity(),
);

final deviceIdentityProvider = FutureProvider<DeviceIdentity>(
  (ref) => ref.watch(deviceServiceProvider).identity(),
);

/// Captures still waiting for a server verdict.
final pendingSubmissionsProvider = FutureProvider<List<QueuedCheckIn>>(
  (ref) => ref.watch(attendanceRepositoryProvider).pendingSubmissions(),
);
