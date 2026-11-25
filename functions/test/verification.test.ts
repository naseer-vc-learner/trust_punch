import { describe, expect, it } from 'vitest';
import { config } from '../src/config';
import { EvaluationInput, evaluateCheckIn, evidenceSupports } from '../src/verification';
import { FlagReason, LivenessEvidence } from '../src/types';

const SITE = {
  id: 'site_hq',
  name: 'HQ',
  latitude: 25.1972,
  longitude: 55.2744,
  radiusMeters: 1000,
};

const NOW = 1_700_000_000_000;

/** Evidence that genuinely supports every prompt we might issue. */
const goodLiveness: LivenessEvidence = {
  completedActions: ['blink_twice'],
  framesAnalysed: 30,
  maxLeftEyeOpenProb: 0.98,
  minLeftEyeOpenProb: 0.05,
  maxHeadEulerAngleY: 25,
  minHeadEulerAngleY: -25,
  faceDetected: true,
};

/** A fully clean on-site check-in. Each test perturbs exactly one thing. */
function baseInput(overrides: Partial<EvaluationInput> = {}): EvaluationInput {
  return {
    type: 'onsite',
    employeeStatus: 'active',
    assignedSiteIds: ['site_hq'],
    siteId: 'site_hq',
    site: SITE,
    location: { latitude: 25.1975, longitude: 55.2748 }, // ~50m from HQ
    accuracyMeters: 10,
    isFromMockProvider: false,
    deviceId: 'device_abc',
    registeredDeviceId: 'device_abc',
    deviceApproved: true,
    deviceBoundToOtherEmployee: false,
    deviceCompromised: false,
    faceMatch: { score: 0.93, faceFound: true, provider: 'mock' },
    liveness: goodLiveness,
    challenge: {
      employeeId: 'emp_1',
      prompts: ['blink_twice'],
      issuedAtMs: NOW - 10_000,
      expiresAtMs: NOW + 60_000,
      consumed: false,
    },
    nowMs: NOW,
    wfhAuthorisedToday: false,
    ...overrides,
  };
}

describe('evaluateCheckIn — happy paths', () => {
  it('approves a clean on-site check-in', () => {
    const d = evaluateCheckIn(baseInput());
    expect(d.status).toBe('approved');
    expect(d.flagReason).toBeNull();
    expect(d.allFlagReasons).toEqual([]);
    expect(d.deviceTrusted).toBe(true);
    expect(d.distanceFromSiteMeters).toBeLessThan(100);
  });

  it('approves an authorised WFH check-in with no location at all', () => {
    const d = evaluateCheckIn(
      baseInput({
        type: 'wfh',
        siteId: null,
        site: null,
        location: null,
        accuracyMeters: null,
        wfhAuthorisedToday: true,
      }),
    );
    expect(d.status).toBe('approved');
    expect(d.distanceFromSiteMeters).toBeNull();
  });
});

describe('geofence', () => {
  it('rejects a check-in outside the site radius', () => {
    const d = evaluateCheckIn(
      baseInput({ location: { latitude: 25.2200, longitude: 55.3100 } }), // ~4.5km
    );
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.OutsideGeofence);
  });

  it('approves just inside the radius', () => {
    // ~0.008 degrees latitude ≈ 890m north of HQ
    const d = evaluateCheckIn(
      baseInput({ location: { latitude: SITE.latitude + 0.008, longitude: SITE.longitude } }),
    );
    expect(d.distanceFromSiteMeters).toBeLessThan(1000);
    expect(d.status).toBe('approved');
  });

  it('uses GPS accuracy as grace at the fence line', () => {
    // ~1.05km out, but with a 100m accuracy circle the employee may be inside.
    const location = { latitude: SITE.latitude + 0.0095, longitude: SITE.longitude };
    const strict = evaluateCheckIn(baseInput({ location, accuracyMeters: 1 }));
    const graced = evaluateCheckIn(baseInput({ location, accuracyMeters: 100 }));

    expect(strict.status).toBe('rejected');
    expect(strict.flagReason).toBe(FlagReason.OutsideGeofence);
    expect(graced.status).toBe('approved');
  });

  it('flags a check-in that is only inside because accuracy is terrible', () => {
    const d = evaluateCheckIn(baseInput({ accuracyMeters: 500 }));
    expect(d.status).toBe('flagged');
    expect(d.flagReason).toBe(FlagReason.LowGpsAccuracy);
  });

  it('rejects a site the employee is not assigned to', () => {
    const d = evaluateCheckIn(baseInput({ assignedSiteIds: ['site_other'] }));
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.SiteNotAssigned);
  });

  it('rejects an on-site check-in with no site document', () => {
    const d = evaluateCheckIn(baseInput({ site: null }));
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.SiteNotAssigned);
  });

  it('falls back to the default radius when the site omits one', () => {
    const d = evaluateCheckIn(
      baseInput({
        site: { ...SITE, radiusMeters: 0 },
        location: { latitude: SITE.latitude + 0.005, longitude: SITE.longitude }, // ~555m
      }),
    );
    expect(config.geo.defaultRadiusMeters).toBe(1000);
    expect(d.status).toBe('approved');
  });
});

describe('mock location', () => {
  it('rejects a spoofed fix even when it lands inside the fence', () => {
    const d = evaluateCheckIn(baseInput({ isFromMockProvider: true }));
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.MockLocationDetected);
  });

  it('reports both mock provider and distance when spoofed from far away', () => {
    const d = evaluateCheckIn(
      baseInput({
        isFromMockProvider: true,
        location: { latitude: 24.0, longitude: 54.0 },
      }),
    );
    expect(d.status).toBe('rejected');
    expect(d.allFlagReasons).toContain(FlagReason.MockLocationDetected);
    expect(d.allFlagReasons).toContain(FlagReason.OutsideGeofence);
  });

  it('ignores the mock flag for WFH, where there is no geofence to spoof', () => {
    const d = evaluateCheckIn(
      baseInput({ type: 'wfh', wfhAuthorisedToday: true, isFromMockProvider: true }),
    );
    expect(d.status).toBe('approved');
  });
});

describe('face match thresholds', () => {
  it('approves at or above the approve threshold', () => {
    const d = evaluateCheckIn(
      baseInput({ faceMatch: { score: config.face.approveThreshold, faceFound: true, provider: 'mock' } }),
    );
    expect(d.status).toBe('approved');
  });

  it('flags a borderline score for human review', () => {
    const d = evaluateCheckIn(
      baseInput({ faceMatch: { score: 0.75, faceFound: true, provider: 'mock' } }),
    );
    expect(d.status).toBe('flagged');
    expect(d.flagReason).toBe(FlagReason.FaceMatchBorderline);
  });

  it('rejects just below the review threshold', () => {
    const d = evaluateCheckIn(
      baseInput({
        faceMatch: { score: config.face.reviewThreshold - 0.001, faceFound: true, provider: 'mock' },
      }),
    );
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.FaceMatchBelowThreshold);
  });

  it('rejects when no face was found in the probe', () => {
    const d = evaluateCheckIn(
      baseInput({ faceMatch: { score: 0.99, faceFound: false, provider: 'mock' } }),
    );
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.NoLiveFaceDetected);
  });
});

describe('liveness', () => {
  it('rejects a missing challenge', () => {
    const d = evaluateCheckIn(baseInput({ challenge: null }));
    expect(d.flagReason).toBe(FlagReason.LivenessChallengeFailed);
  });

  it('rejects an expired challenge', () => {
    const input = baseInput();
    const d = evaluateCheckIn({ ...input, nowMs: input.challenge!.expiresAtMs + 1 });
    expect(d.flagReason).toBe(FlagReason.LivenessChallengeExpired);
  });

  it('rejects a challenge that was already consumed — the replay case', () => {
    const input = baseInput();
    const d = evaluateCheckIn({
      ...input,
      challenge: { ...input.challenge!, consumed: true },
    });
    expect(d.flagReason).toBe(FlagReason.LivenessChallengeExpired);
  });

  it('rejects when the claimed action is not the one that was asked for', () => {
    const input = baseInput();
    const d = evaluateCheckIn({
      ...input,
      challenge: { ...input.challenge!, prompts: ['turn_head_left'] },
      liveness: { ...goodLiveness, completedActions: ['blink_twice'] },
    });
    expect(d.flagReason).toBe(FlagReason.LivenessChallengeFailed);
  });

  it('rejects a claimed blink the frame telemetry does not support', () => {
    const d = evaluateCheckIn(
      baseInput({
        liveness: { ...goodLiveness, maxLeftEyeOpenProb: 0.95, minLeftEyeOpenProb: 0.9 },
      }),
    );
    expect(d.flagReason).toBe(FlagReason.LivenessChallengeFailed);
  });

  it('rejects too few analysed frames — a single still photo', () => {
    const d = evaluateCheckIn(baseInput({ liveness: { ...goodLiveness, framesAnalysed: 3 } }));
    expect(d.flagReason).toBe(FlagReason.LivenessChallengeFailed);
  });

  it('rejects when no face was seen during the challenge', () => {
    const d = evaluateCheckIn(baseInput({ liveness: { ...goodLiveness, faceDetected: false } }));
    expect(d.flagReason).toBe(FlagReason.NoLiveFaceDetected);
  });
});

describe('evidenceSupports', () => {
  it('accepts a real blink and rejects a static eye', () => {
    expect(evidenceSupports('blink_twice', goodLiveness)).toBe(true);
    expect(
      evidenceSupports('blink_twice', {
        ...goodLiveness,
        maxLeftEyeOpenProb: 0.9,
        minLeftEyeOpenProb: 0.85,
      }),
    ).toBe(false);
  });

  it('distinguishes left from right head turns', () => {
    const left = { ...goodLiveness, minHeadEulerAngleY: -30, maxHeadEulerAngleY: 2 };
    expect(evidenceSupports('turn_head_left', left)).toBe(true);
    expect(evidenceSupports('turn_head_right', left)).toBe(false);
  });

  it('refuses a prompt it does not know how to verify', () => {
    expect(evidenceSupports('do_a_backflip', goodLiveness)).toBe(false);
  });
});

describe('device trust', () => {
  it('blocks a rooted device outright', () => {
    const d = evaluateCheckIn(baseInput({ deviceCompromised: true }));
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.CompromisedDevice);
  });

  it('flags an unknown device instead of locking the employee out', () => {
    const d = evaluateCheckIn(
      baseInput({ deviceId: 'device_new', deviceApproved: null, registeredDeviceId: 'device_abc' }),
    );
    expect(d.status).toBe('flagged');
    expect(d.flagReason).toBe(FlagReason.UnregisteredDevice);
    expect(d.deviceTrusted).toBe(false);
  });

  it('flags a device still awaiting admin approval', () => {
    const d = evaluateCheckIn(baseInput({ deviceApproved: false }));
    expect(d.status).toBe('flagged');
    expect(d.flagReason).toBe(FlagReason.DevicePendingApproval);
  });

  it('flags a device registered to someone else — the buddy-punch signal', () => {
    const d = evaluateCheckIn(baseInput({ deviceBoundToOtherEmployee: true }));
    expect(d.status).toBe('flagged');
    expect(d.flagReason).toBe(FlagReason.DeviceSharedAcrossEmployees);
    expect(d.deviceTrusted).toBe(false);
  });

  it('flags an approved device that is not the employee’s registered one', () => {
    const d = evaluateCheckIn(
      baseInput({ deviceId: 'device_xyz', registeredDeviceId: 'device_abc', deviceApproved: true }),
    );
    expect(d.status).toBe('flagged');
    expect(d.flagReason).toBe(FlagReason.UnregisteredDevice);
  });
});

describe('WFH authorisation', () => {
  it('rejects WFH on a day with no approved exception', () => {
    const d = evaluateCheckIn(
      baseInput({ type: 'wfh', site: null, siteId: null, wfhAuthorisedToday: false }),
    );
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.WfhNotAuthorised);
  });
});

describe('account status', () => {
  it('rejects a suspended employee before anything else', () => {
    const d = evaluateCheckIn(baseInput({ employeeStatus: 'suspended' }));
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.EmployeeInactive);
  });
});

describe('reason precedence', () => {
  it('reports a rejecting reason even when a flagging one came first', () => {
    const d = evaluateCheckIn(
      baseInput({
        deviceApproved: false, // flagging
        isFromMockProvider: true, // rejecting
      }),
    );
    expect(d.status).toBe('rejected');
    expect(d.flagReason).toBe(FlagReason.MockLocationDetected);
    expect(d.allFlagReasons).toContain(FlagReason.DevicePendingApproval);
  });

  it('always returns a non-empty message the client can display', () => {
    const d = evaluateCheckIn(baseInput({ deviceCompromised: true }));
    expect(d.message.length).toBeGreaterThan(0);
  });
});
