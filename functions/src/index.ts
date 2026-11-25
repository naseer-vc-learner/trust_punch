import * as admin from 'firebase-admin';

admin.initializeApp();

export { submitCheckIn } from './submitCheckIn';
export { issueLivenessChallenge } from './challenges';
export { registerDevice, approveDevice } from './devices';
export {
  enrollFace,
  resetFaceEnrollment,
  setAdminClaim,
  registerFcmToken,
} from './enrollment';
export {
  requestWfhDay,
  approveWfhDay,
  planPresencePings,
  dispatchPresencePings,
  respondToPresencePing,
} from './wfh';
export { flagAnomalies } from './flagAnomalies';
export { reviewAttendanceRecord } from './review';
