import { createHash } from 'crypto';
import * as jpeg from 'jpeg-js';
import {
  DuplicateMatch,
  EnrollmentResult,
  FaceMatcher,
  FaceMatchResult,
} from './FaceMatcher';

/**
 * Where templates live. Firestore in prod, a Map in tests.
 *
 * `listAll` exists for duplicate detection, which is inherently one-to-many.
 */
export interface TemplateStore {
  put(ref: string, vector: number[], employeeId: string): Promise<void>;
  get(ref: string): Promise<number[] | null>;
  delete(ref: string): Promise<void>;
  listAll(): Promise<Array<{ ref: string; employeeId: string; vector: number[] }>>;
}

export class InMemoryTemplateStore implements TemplateStore {
  private readonly data = new Map<string, { vector: number[]; employeeId: string }>();

  async put(ref: string, vector: number[], employeeId: string): Promise<void> {
    this.data.set(ref, { vector, employeeId });
  }
  async get(ref: string): Promise<number[] | null> {
    return this.data.get(ref)?.vector ?? null;
  }
  async delete(ref: string): Promise<void> {
    this.data.delete(ref);
  }
  async listAll() {
    return [...this.data.entries()].map(([ref, v]) => ({ ref, ...v }));
  }
}

/** Edge of the square the image is reduced to before comparison. */
const GRID = 32;

/**
 * Offline stand-in for a face vendor.
 *
 * ## What changed and why
 *
 * The first version hashed raw JPEG *bytes*, which was worse than useless: a
 * JPEG's entropy-coded payload is near-uniform noise whatever the subject, so
 * any two photos scored ~1.0 and every face matched every employee. That is the
 * single most dangerous kind of bug in this app — verification that always says
 * yes looks identical to verification that works.
 *
 * This version decodes to actual pixels and compares image *structure*:
 * grayscale, downscaled to 32×32, contrast-normalised. Different people now
 * score far apart, so enrollment genuinely binds an identity.
 *
 * ## What it still is NOT
 *
 * It is not face recognition. It compares whole images, so it is sensitive to
 * lighting, pose and background in ways a real embedding is not — expect false
 * rejections when someone moves or the light changes. It is good enough to
 * demonstrate and test the pipeline offline; it is not good enough to pay
 * people by. Ship a real provider before production (see faceMatch/index.ts).
 */
export class MockFaceMatcher implements FaceMatcher {
  readonly provider = 'mock';

  constructor(private readonly store: TemplateStore) {}

  async enroll(employeeId: string, frames: Buffer[]): Promise<EnrollmentResult> {
    const vectors = frames.map(featureVector).filter((v): v is number[] => v !== null);
    if (vectors.length === 0) {
      throw new Error('No usable enrollment frames — none decoded as an image');
    }

    // Average the per-angle vectors, the way a real provider averages the
    // embeddings of several poses into one identity template.
    const mean = vectors[0].map(
      (_, i) => vectors.reduce((sum, v) => sum + v[i], 0) / vectors.length,
    );

    const ref = `mock:${createHash('sha256').update(employeeId).digest('hex').slice(0, 24)}`;
    await this.store.put(ref, mean, employeeId);

    return { embeddingRef: ref, acceptedFrames: vectors.length, provider: this.provider };
  }

  async match(embeddingRef: string, probe: Buffer): Promise<FaceMatchResult> {
    const forced = process.env.FACE_MOCK_FORCED_SCORE;
    if (forced !== undefined && forced !== '') {
      return { score: Number(forced), faceFound: true, provider: this.provider };
    }

    const probeVector = featureVector(probe);
    if (!probeVector) {
      return { score: 0, faceFound: false, provider: this.provider };
    }
    const template = await this.store.get(embeddingRef);
    if (!template) throw new Error(`Unknown embedding ref: ${embeddingRef}`);

    return {
      score: similarity(template, probeVector),
      faceFound: true,
      provider: this.provider,
    };
  }

  async findDuplicates(
    probe: Buffer,
    options: { excludeEmployeeId?: string; threshold?: number } = {},
  ): Promise<DuplicateMatch[]> {
    const probeVector = featureVector(probe);
    if (!probeVector) return [];

    const threshold = options.threshold ?? 0.9;
    const all = await this.store.listAll();

    return all
      .filter((t) => t.employeeId !== options.excludeEmployeeId)
      .map((t) => ({
        employeeId: t.employeeId,
        embeddingRef: t.ref,
        score: similarity(t.vector, probeVector),
      }))
      .filter((m) => m.score >= threshold)
      .sort((a, b) => b.score - a.score);
  }

  async deleteEnrollment(embeddingRef: string): Promise<void> {
    await this.store.delete(embeddingRef);
  }
}

/**
 * Decode → grayscale → 32×32 → contrast-normalise.
 *
 * Normalising to zero mean and unit variance is what stops overall brightness
 * dominating the comparison; without it, two photos taken in the same room
 * score highly whoever is in them — which is precisely how the byte-histogram
 * version failed.
 *
 * Returns null when the buffer is not a decodable JPEG, which the caller must
 * treat as "no face found" rather than as a zero score.
 */
export function featureVector(bytes: Buffer): number[] | null {
  if (bytes.length === 0) return null;

  let decoded: { width: number; height: number; data: Buffer | Uint8Array };
  try {
    decoded = jpeg.decode(bytes, { useTArray: true, maxMemoryUsageInMB: 64 });
  } catch {
    return null;
  }
  const { width, height, data } = decoded;
  if (!width || !height) return null;

  const cells = new Array<number>(GRID * GRID).fill(0);
  const counts = new Array<number>(GRID * GRID).fill(0);

  // Box-average every source pixel into its cell — cheap area downscale.
  for (let y = 0; y < height; y++) {
    const gy = Math.min(GRID - 1, Math.floor((y / height) * GRID));
    for (let x = 0; x < width; x++) {
      const gx = Math.min(GRID - 1, Math.floor((x / width) * GRID));
      const i = (y * width + x) * 4;
      // Rec. 601 luma
      const luma = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
      const cell = gy * GRID + gx;
      cells[cell] += luma;
      counts[cell] += 1;
    }
  }

  for (let i = 0; i < cells.length; i++) {
    if (counts[i] > 0) cells[i] /= counts[i];
  }

  const mean = cells.reduce((a, b) => a + b, 0) / cells.length;
  const variance =
    cells.reduce((sum, v) => sum + (v - mean) * (v - mean), 0) / cells.length;
  const stdDev = Math.sqrt(variance) || 1;

  return cells.map((v) => (v - mean) / stdDev);
}

/**
 * Correlation of two normalised vectors, mapped to 0..1.
 *
 * Cosine similarity on *centred* data is Pearson correlation, which is what
 * makes "different image" land near 0.5 instead of near 1.0.
 */
export function similarity(a: number[], b: number[]): number {
  const raw = cosineSimilarity(a, b);
  return Math.max(0, Math.min(1, (raw + 1) / 2));
}

export function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (normA === 0 || normB === 0) return 0;
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}
