import { randomInt } from 'crypto';
import * as admin from 'firebase-admin';
import { Timestamp } from 'firebase-admin/firestore';
import { onCall } from 'firebase-functions/v2/https';
import { config, REGION } from './config';
import { requireAuth } from './lib/guards';
import { LivenessChallenge } from './types';

/**
 * ## issueLivenessChallenge
 *
 * Issues a short-lived, single-use liveness prompt.
 *
 * Why server-side: if the app picked its own prompt, a recorded video of the
 * employee blinking could be replayed forever. Because the server chooses the
 * prompt, binds it to one employee, expires it in 90s and marks it consumed on
 * use, an attacker would need a video that satisfies a prompt they cannot
 * predict — which is the point of the challenge.
 */

export const CHALLENGE_PROMPTS = [
  'blink_twice',
  'turn_head_left',
  'turn_head_right',
  'look_straight_then_left',
] as const;

export const CHALLENGES_COLLECTION = 'liveness_challenges';

export const issueLivenessChallenge = onCall({ region: REGION }, async (req) => {
  const uid = requireAuth(req);
  const now = Date.now();

  const prompt = CHALLENGE_PROMPTS[randomInt(CHALLENGE_PROMPTS.length)];
  const challenge: LivenessChallenge = {
    employeeId: uid,
    prompts: [prompt],
    issuedAtMs: now,
    expiresAtMs: now + config.liveness.challengeTtlSeconds * 1000,
    consumed: false,
  };

  const ref = await admin.firestore().collection(CHALLENGES_COLLECTION).add({
    ...challenge,
    // TTL policy on this field lets Firestore garbage-collect spent challenges.
    expiresAt: Timestamp.fromMillis(challenge.expiresAtMs),
  });

  return {
    challengeId: ref.id,
    prompts: challenge.prompts,
    expiresAtMs: challenge.expiresAtMs,
    ttlSeconds: config.liveness.challengeTtlSeconds,
  };
});
