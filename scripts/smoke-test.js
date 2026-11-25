#!/usr/bin/env node
/**
 * End-to-end smoke test against the running emulators.
 *
 * Drives the real callables in the real order an employee would:
 *   sign in -> register device -> enroll face -> get challenge -> check in
 * then deliberately fails a check-in three ways to prove the rejections work.
 *
 * Requires: emulators running + `node scripts/seed-emulator.js` already run.
 *   node scripts/smoke-test.js
 */

const FUNCTIONS = 'http://127.0.0.1:5001/demo-trustpunch/europe-west1';
const AUTH = 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1';
/**
 * Read from the emulator rather than hardcoded, so the test follows whatever
 * coordinates `seed-emulator.js` was configured with. A stale constant here
 * geofences every check-in out and makes unrelated assertions look broken.
 *
 * Uses the Admin SDK because the REST API is subject to the security rules,
 * which correctly deny an unauthenticated read of `sites`.
 */
let SITE = { latitude: 0, longitude: 0 };

async function loadSite() {
  process.env.FIRESTORE_EMULATOR_HOST = 'localhost:8080';
  const admin = require(path.join(__dirname, '..', 'functions', 'node_modules', 'firebase-admin'));
  if (admin.apps.length === 0) admin.initializeApp({ projectId: 'demo-trustpunch' });

  const snap = await admin.firestore().collection('sites').doc('site_hq').get();
  if (!snap.exists) throw new Error('site_hq not found — run: node scripts/seed-emulator.js');
  SITE = { latitude: snap.data().latitude, longitude: snap.data().longitude };
}

let idToken;
let passed = 0;
let failed = 0;

const path = require('path');
const jpeg = require(path.join(__dirname, '..', 'functions', 'node_modules', 'jpeg-js'));

/**
 * A synthetic but genuinely decodable "face".
 *
 * Real JPEG pixels matter now: the matcher decodes the image and compares its
 * structure, so random bytes would simply fail to decode. Each `person` seed
 * produces a distinct arrangement of light and dark regions; `variant` nudges
 * lighting and position to stand in for the same person photographed twice.
 */
function faceJpeg(person, variant = 0, width = 160, height = 160) {
  const data = Buffer.alloc(width * height * 4);
  const rand = (n) => {
    let x = (person * 7919 + n * 104729) & 0x7fffffff;
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    return (x % 1000) / 1000;
  };
  const blobs = [0, 1, 2].map((i) => ({
    cx: 0.2 + rand(i * 3) * 0.6,
    cy: 0.2 + rand(i * 3 + 1) * 0.6,
    r: 0.12 + rand(i * 3 + 2) * 0.18,
  }));

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const nx = x / width;
      const ny = y / height;
      let v = 60 + variant * 12;
      for (const b of blobs) {
        const dx = nx - b.cx - variant * 0.01;
        const dy = ny - b.cy;
        if (Math.sqrt(dx * dx + dy * dy) < b.r) v += 90;
      }
      const i = (y * width + x) * 4;
      data[i] = data[i + 1] = data[i + 2] = Math.min(255, v);
      data[i + 3] = 255;
    }
  }
  return jpeg.encode({ data, width, height }, 92).data.toString('base64');
}

/** The enrolled employee's face. */
const MY_FACE = faceJpeg(1, 1);
/** Somebody else entirely. */
const OTHER_FACE = faceJpeg(42);

/** Telemetry that supports every prompt the server might issue. */
const goodLiveness = {
  framesAnalysed: 30,
  maxLeftEyeOpenProb: 0.98,
  minLeftEyeOpenProb: 0.02,
  maxHeadEulerAngleY: 30,
  minHeadEulerAngleY: -30,
  faceDetected: true,
};

async function call(name, data) {
  const res = await fetch(`${FUNCTIONS}/${name}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(idToken ? { Authorization: `Bearer ${idToken}` } : {}),
    },
    body: JSON.stringify({ data }),
  });
  const body = await res.json();
  if (body.error) throw new Error(`${name}: ${body.error.message}`);
  return body.result;
}

function check(label, actual, expected) {
  const ok = actual === expected;
  console.log(`  ${ok ? '✔' : '✘'} ${label.padEnd(46)} ${actual}`);
  ok ? passed++ : failed++;
}

async function signIn(email) {
  const res = await fetch(`${AUTH}/accounts:signInWithPassword?key=fake-api-key`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: 'Test123!', returnSecureToken: true }),
  });
  const body = await res.json();
  if (!body.idToken) throw new Error(`sign-in failed: ${JSON.stringify(body)}`);
  idToken = body.idToken;
  return body.localId;
}

/** One check-in with a fresh challenge; overrides let each case bend one input. */
async function checkIn(overrides = {}) {
  const challenge = await call('issueLivenessChallenge', {});
  return call('submitCheckIn', {
    type: 'onsite',
    siteId: 'site_hq',
    selfieBase64: MY_FACE,
    deviceId: 'device_smoke_test',
    challengeId: challenge.challengeId,
    clientNonce: `nonce_${Math.random().toString(36).slice(2)}`,
    latitude: SITE.latitude,
    longitude: SITE.longitude,
    accuracyMeters: 8,
    isFromMockProvider: false,
    deviceCompromised: false,
    livenessEvidence: { ...goodLiveness, completedActions: challenge.prompts },
    ...overrides,
  });
}

async function run() {
  console.log('\nTrustPunch end-to-end smoke test (emulators)\n');

  console.log('Setup');
  await loadSite();
  console.log(`  ✔ site loaded: ${SITE.latitude}, ${SITE.longitude}`);
  await signIn('employee2@test.local');
  console.log('  ✔ signed in as employee2@test.local');

  const device = await call('registerDevice', {
    deviceId: 'device_smoke_test',
    platform: 'android',
    model: 'Smoke Test Device',
    compromised: false,
  });
  check('first device auto-approved', device.status, 'approved');

  const enrollment = await call('enrollFace', {
    framesBase64: [0, 1, 2, 3, 4].map((v) => faceJpeg(1, v)),
  });
  check('face enrolled from 5 frames', enrollment.acceptedFrames, 5);

  console.log('\nHappy path — a full working day');
  const ok = await checkIn();
  check('check in', ok.status, 'approved');
  check('  session open', ok.sessionStatus, 'open');
  check('  distance computed', Math.round(ok.distanceFromSiteMeters), 0);

  const breakOn = await checkIn({ direction: 'break_start' });
  check('start break', breakOn.sessionStatus, 'on_break');

  const dupBreak = await checkIn({ direction: 'break_start' });
  check('  second break refused', dupBreak.flagReason, 'ALREADY_ON_BREAK');

  const breakOff = await checkIn({ direction: 'break_end' });
  check('end break', breakOff.sessionStatus, 'open');

  const reCheckIn = await checkIn();
  check('  double check-in refused', reCheckIn.flagReason, 'ALREADY_CHECKED_IN');

  const out = await checkIn({ direction: 'out' });
  check('check out', out.sessionStatus, 'closed');
  check('  hours computed', typeof out.workedMinutes, 'number');

  const doubleOut = await checkIn({ direction: 'out' });
  check('  checkout with nothing open refused', doubleOut.flagReason, 'NO_OPEN_CHECK_IN');

  console.log('\nRejections');
  const mocked = await checkIn({ isFromMockProvider: true });
  check('spoofed GPS rejected', mocked.flagReason, 'MOCK_LOCATION_DETECTED');

  const faraway = await checkIn({ latitude: 24.0, longitude: 54.0 });
  check('outside geofence rejected', faraway.flagReason, 'OUTSIDE_GEOFENCE');

  const noBlink = await checkIn({
    livenessEvidence: {
      ...goodLiveness,
      // No blink (flat eye probability) AND no head movement (flat yaw), so
      // whichever prompt the server picked, the telemetry cannot support it.
      maxLeftEyeOpenProb: 0.9,
      minLeftEyeOpenProb: 0.85,
      maxHeadEulerAngleY: 2,
      minHeadEulerAngleY: -2,
      completedActions: ['blink_twice', 'turn_head_left', 'turn_head_right', 'look_straight_then_left'],
    },
  });
  check('unsupported liveness claim rejected', noBlink.flagReason, 'LIVENESS_CHALLENGE_FAILED');

  const rooted = await checkIn({ deviceCompromised: true });
  check('rooted device rejected', rooted.flagReason, 'COMPROMISED_DEVICE');

  console.log('\nIdentity binding');
  const wrongFace = await checkIn({ selfieBase64: OTHER_FACE });
  check('a different face is rejected', wrongFace.flagReason, 'FACE_MATCH_BELOW_THRESHOLD');

  const rightFace = await checkIn({ selfieBase64: faceJpeg(1, 3) });
  check('the enrolled face still passes', rightFace.status, 'approved');
  await checkIn({ direction: 'out' }); // leave the day closed for later cases

  console.log('\nDuplicate face across employees');
  const before = idToken;
  await signIn('employee3@test.local');
  await call('registerDevice', {
    deviceId: 'device_smoke_test_2',
    platform: 'android',
    model: 'Second Device',
    compromised: false,
  });
  let duplicateBlocked = 'not blocked';
  try {
    // Same face, different employee — the buddy-punching setup.
    await call('enrollFace', { framesBase64: [0, 1, 2, 3, 4].map((v) => faceJpeg(1, v)) });
  } catch (err) {
    duplicateBlocked = /already registered to another employee/.test(err.message)
      ? 'blocked'
      : err.message;
  }
  check('same face under a second name is blocked', duplicateBlocked, 'blocked');

  const distinct = await call('enrollFace', {
    framesBase64: [0, 1, 2, 3, 4].map((v) => faceJpeg(77, v)),
  });
  check('a genuinely new face still enrolls', distinct.enrolled, true);
  idToken = before;

  console.log('\nReplay protection');
  const challenge = await call('issueLivenessChallenge', {});
  const payload = {
    type: 'onsite',
    siteId: 'site_hq',
    selfieBase64: MY_FACE,
    deviceId: 'device_smoke_test',
    challengeId: challenge.challengeId,
    latitude: SITE.latitude,
    longitude: SITE.longitude,
    accuracyMeters: 8,
    livenessEvidence: { ...goodLiveness, completedActions: challenge.prompts },
  };
  const first = await call('submitCheckIn', { ...payload, clientNonce: 'replay_a' });
  check('first use of challenge', first.status, 'approved');
  // Same challenge, different nonce — the idempotency shortcut cannot mask this.
  const replay = await call('submitCheckIn', { ...payload, clientNonce: 'replay_b' });
  check('replayed challenge rejected', replay.flagReason, 'LIVENESS_CHALLENGE_EXPIRED');

  const dup = await call('submitCheckIn', { ...payload, clientNonce: 'replay_a' });
  check('duplicate nonce returns original', dup.recordId, first.recordId);
  await checkIn({ direction: 'out' });

  console.log(`\n${passed} passed, ${failed} failed\n`);
  process.exit(failed === 0 ? 0 : 1);
}

run().catch((err) => {
  console.error('\nSmoke test failed:', err.message);
  console.error('Are the emulators running and seeded?\n');
  process.exit(1);
});
