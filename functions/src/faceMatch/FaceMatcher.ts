/**
 * Pluggable face matching.
 *
 * Everything vendor-specific lives behind this interface so `submitCheckIn`
 * never imports an SDK. Swapping in AWS Rekognition / Azure Face / CompreFace
 * means adding one file and one line in `index.ts` of this folder — the
 * verification logic and its tests do not change.
 */

export interface FaceMatchResult {
  /** 0..1. Higher is more confident this is the enrolled person. */
  score: number;
  /** False when the probe image contains no usable face at all. */
  faceFound: boolean;
  /** Vendor name, persisted on the record so scores stay comparable. */
  provider: string;
  /** Optional vendor-native liveness/quality signal, if the provider has one. */
  providerLivenessScore?: number;
}

export interface EnrollmentResult {
  /** Opaque handle stored on the employee as `faceEmbeddingRef`. */
  embeddingRef: string;
  /** How many of the submitted frames produced a usable embedding. */
  acceptedFrames: number;
  provider: string;
}

/** One already-enrolled person whose face resembles a probe. */
export interface DuplicateMatch {
  employeeId: string;
  embeddingRef: string;
  score: number;
}

export interface FaceMatcher {
  readonly provider: string;

  /**
   * Find already-enrolled people whose face matches this probe.
   *
   * Called at enrollment to stop one person registering twice under two names —
   * the failure mode where "Ali" and "Sam" are the same face and each covers
   * the other's attendance. Per-check-in verification cannot catch this: both
   * identities would match their own template perfectly.
   *
   * Maps onto `SearchFacesByImage` (Rekognition) or `Face - Find Similar`
   * (Azure) — every serious vendor exposes a one-to-many search for exactly
   * this reason.
   */
  findDuplicates(
    probe: Buffer,
    options?: { excludeEmployeeId?: string; threshold?: number },
  ): Promise<DuplicateMatch[]>;

  /**
   * Build a reusable identity template from enrollment frames.
   * Implementations must NOT retain the raw images beyond this call.
   */
  enroll(employeeId: string, frames: Buffer[]): Promise<EnrollmentResult>;

  /** Compare a probe selfie against a previously enrolled template. */
  match(embeddingRef: string, probe: Buffer): Promise<FaceMatchResult>;

  /** Remove stored biometric data for an employee (GDPR erasure path). */
  deleteEnrollment(embeddingRef: string): Promise<void>;
}
