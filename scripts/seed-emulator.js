#!/usr/bin/env node
/**
 * Seeds the LOCAL EMULATORS with test data. Touches nothing in the cloud.
 *
 * No service-account key is needed: against a `demo-` project the Admin SDK
 * talks to the emulator hosts in the environment variables below and skips
 * credentials entirely.
 *
 * Start the emulators first (`npm --prefix functions run serve`), then:
 *   node scripts/seed-emulator.js
 *
 * Re-runnable: the emulators start empty each time unless you export data.
 */

const path = require('path');

// Must be set BEFORE the Admin SDK initialises — it reads them at startup.
// Ports match the `emulators` block in firebase.json.
process.env.FIRESTORE_EMULATOR_HOST = 'localhost:8080';
process.env.FIREBASE_AUTH_EMULATOR_HOST = 'localhost:9099';
process.env.FIREBASE_STORAGE_EMULATOR_HOST = 'localhost:9199';

const PROJECT_ID = 'demo-trustpunch';

let admin;
try {
  admin = require('firebase-admin');
} catch {
  admin = require(path.join(__dirname, '..', 'functions', 'node_modules', 'firebase-admin'));
}

admin.initializeApp({ projectId: PROJECT_ID });

const db = admin.firestore();
const auth = admin.auth();

/** One site, centred wherever you are testing from. */
const SITES = [
  {
    id: 'site_hq',
    name: 'Desert Group India',
    latitude: 12.885079,
    longitude: 74.8785669,
    radiusMeters: 1000,
  },
];

/** Ten test users: one admin, one manager, eight employees. */
const PASSWORD = 'Test123!';
const PEOPLE = [
  { email: 'admin@test.local', name: 'Test Admin', role: 'admin' },
  { email: 'manager@test.local', name: 'Test Manager', role: 'manager' },
  ...Array.from({ length: 8 }, (_, i) => ({
    email: `employee${i + 1}@test.local`,
    name: `Test Employee ${i + 1}`,
    role: 'employee',
  })),
];

async function run() {
  console.log(`\nSeeding EMULATORS for ${PROJECT_ID} — nothing reaches the cloud.\n`);

  // Employee docs are reset below, which clears faceEmbeddingRef — but the
  // templates live in their own collection. Left behind, they would both block
  // re-enrollment and make every fresh enrollment look like a duplicate face.
  for (const name of [
    'face_templates',
    'work_sessions',
    'enrollment_alerts',
    'devices',
    'attendance',
  ]) {
    const snap = await db.collection(name).get();
    await Promise.all(snap.docs.map((d) => d.ref.delete()));
    if (snap.size > 0) console.log(`  clear  ${name} (${snap.size})`);
  }

  for (const { id, ...site } of SITES) {
    await db.collection('sites').doc(id).set(site);
    console.log(`  site   ${id} — ${site.name} (${site.radiusMeters}m radius)`);
  }

  for (const person of PEOPLE) {
    let user;
    try {
      user = await auth.getUserByEmail(person.email);
    } catch {
      user = await auth.createUser({
        email: person.email,
        password: PASSWORD,
        displayName: person.name,
      });
    }

    if (person.role === 'admin') {
      await auth.setCustomUserClaims(user.uid, { admin: true });
    }

    await db.collection('employees').doc(user.uid).set({
      name: person.name,
      email: person.email,
      role: person.role,
      assignedSiteIds: ['site_hq'],
      registeredDeviceId: null,
      faceEmbeddingRef: null,
      status: 'pending_enrollment',
      fcmTokens: [],
    });
    console.log(`  user   ${person.email.padEnd(24)} ${person.role}`);
  }

  // An approved WFH day for today, so the work-from-home path is testable
  // immediately instead of needing a manager approval round-trip first.
  const today = new Date().toISOString().slice(0, 10);
  const wfhUser = await auth.getUserByEmail('employee1@test.local');
  await db.collection('wfh_exceptions').doc(`${wfhUser.uid}_${today}`).set({
    employeeId: wfhUser.uid,
    date: today,
    reason: 'Seeded for testing',
    approvedBy: 'system:seed',
    approvedAt: admin.firestore.Timestamp.now(),
  });
  console.log(`\n  wfh    employee1@test.local approved for ${today}`);

  console.log(
    `\nDone. Sign in with any address above, password: ${PASSWORD}\n` +
      'Emulator UI: http://localhost:4000\n',
  );
  process.exit(0);
}

run().catch((err) => {
  console.error(
    '\nSeeding failed. Are the emulators running?\n' +
      '  npm --prefix functions run serve\n\n',
    err.message,
  );
  process.exit(1);
});
