#!/usr/bin/env node
/**
 * One-off setup script: creates sites, employees and the first admin.
 *
 * These three things cannot be done from the app. `sites` and `employees` are
 * admin-write-only in the security rules, and `setAdminClaim` requires an
 * existing admin — so the first one has to come from a trusted shell like this.
 *
 * Usage:
 *   1. Download a service account key:
 *      Console -> Project settings -> Service accounts -> Generate new private key
 *      Save it as scripts/service-account.json  (already gitignored)
 *
 *   2. node scripts/seed.js
 *
 * Safe to re-run: every write is a merge, and existing employees are not reset.
 */

const path = require('path');

// firebase-admin lives in functions/node_modules — there is no package.json at
// the repo root, so resolve it explicitly rather than making you npm install twice.
let admin;
try {
  admin = require('firebase-admin');
} catch {
  admin = require(path.join(__dirname, '..', 'functions', 'node_modules', 'firebase-admin'));
}

// ---------------------------------------------------------------------------
// EDIT THIS BLOCK, then run the script.
// ---------------------------------------------------------------------------

const SITES = [
  {
    id: 'site_hq',
    name: 'Head Office',
    latitude: 25.1972, // <- replace with your real site coordinates
    longitude: 55.2744,
    radiusMeters: 1000,
  },
  // { id: 'site_warehouse', name: 'Warehouse', latitude: 0, longitude: 0, radiusMeters: 500 },
];

const EMPLOYEES = [
  {
    email: 'admin@yourcompany.com', // <- your own account; becomes the admin
    password: 'ChangeMe123!', // only used if the auth user does not exist yet
    name: 'Your Name',
    role: 'admin',
    assignedSiteIds: ['site_hq'],
  },
  // {
  //   email: 'aisha@yourcompany.com',
  //   password: 'ChangeMe123!',
  //   name: 'Aisha Khan',
  //   role: 'employee',
  //   assignedSiteIds: ['site_hq'],
  // },
];

// ---------------------------------------------------------------------------

const keyPath = path.join(__dirname, 'service-account.json');
let serviceAccount;
try {
  serviceAccount = require(keyPath);
} catch {
  console.error(
    `\nMissing ${keyPath}\n\n` +
      'Download it from: Console -> Project settings -> Service accounts ->\n' +
      'Generate new private key, and save it at that path.\n',
  );
  process.exit(1);
}

admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });

const db = admin.firestore();
const auth = admin.auth();

async function seedSites() {
  for (const { id, ...site } of SITES) {
    await db.collection('sites').doc(id).set(site, { merge: true });
    console.log(`  site   ${id} — ${site.name} (r=${site.radiusMeters}m)`);
  }
}

async function seedEmployees() {
  for (const person of EMPLOYEES) {
    // Reuse the auth user if it exists; the uid is what binds everything.
    let user;
    try {
      user = await auth.getUserByEmail(person.email);
      console.log(`  auth   ${person.email} — exists (${user.uid})`);
    } catch {
      user = await auth.createUser({
        email: person.email,
        password: person.password,
        displayName: person.name,
      });
      console.log(`  auth   ${person.email} — created (${user.uid})`);
    }

    // Admin identity lives in a custom claim, not a Firestore field, so no
    // document write anywhere can escalate privilege.
    if (person.role === 'admin') {
      await auth.setCustomUserClaims(user.uid, { admin: true });
      console.log(`  claim  ${person.email} — admin: true`);
    }

    const ref = db.collection('employees').doc(user.uid);
    const existing = await ref.get();

    await ref.set(
      {
        name: person.name,
        email: person.email,
        role: person.role,
        assignedSiteIds: person.assignedSiteIds,
        // Never reset an enrolled employee's trust anchors on a re-run.
        ...(existing.exists
          ? {}
          : {
              registeredDeviceId: null,
              faceEmbeddingRef: null,
              status: 'pending_enrollment',
              fcmTokens: [],
            }),
      },
      { merge: true },
    );
    console.log(`  doc    employees/${user.uid} — ${person.role}`);
  }
}

(async () => {
  console.log(`\nSeeding project: ${serviceAccount.project_id}\n`);
  await seedSites();
  await seedEmployees();
  console.log(
    '\nDone.\n\n' +
      'Admins must sign out and back in for the new claim to appear in their\n' +
      'ID token — a cached token still says they are not an admin.\n',
  );
  process.exit(0);
})().catch((err) => {
  console.error('\nSeeding failed:', err);
  process.exit(1);
});
