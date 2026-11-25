import * as admin from 'firebase-admin';
import { Timestamp } from 'firebase-admin/firestore';
import { config } from '../config';
import { FaceMatcher } from './FaceMatcher';
import { MockFaceMatcher, TemplateStore } from './MockFaceMatcher';

export * from './FaceMatcher';
export * from './MockFaceMatcher';

/** Firestore-backed template store for the mock provider. */
class FirestoreTemplateStore implements TemplateStore {
  private get col() {
    return admin.firestore().collection('face_templates');
  }
  async put(ref: string, vector: number[], employeeId: string): Promise<void> {
    await this.col
      .doc(encodeURIComponent(ref))
      .set({ vector, employeeId, updatedAt: Timestamp.now() });
  }
  async get(ref: string): Promise<number[] | null> {
    const snap = await this.col.doc(encodeURIComponent(ref)).get();
    return snap.exists ? ((snap.data()?.vector as number[]) ?? null) : null;
  }
  async delete(ref: string): Promise<void> {
    await this.col.doc(encodeURIComponent(ref)).delete();
  }
  async listAll() {
    // Enrollment is rare and the roster is small, so a full scan is fine here.
    // A real vendor does this search inside its own index instead.
    const snap = await this.col.get();
    return snap.docs.map((d) => ({
      ref: decodeURIComponent(d.id),
      employeeId: (d.data().employeeId as string) ?? '',
      vector: (d.data().vector as number[]) ?? [],
    }));
  }
}

let cached: FaceMatcher | null = null;

/**
 * Resolve the configured provider.
 *
 * To add a real vendor: implement `FaceMatcher` in this folder (e.g.
 * `RekognitionFaceMatcher.ts`, using a CollectionId per tenant and
 * `SearchFacesByImage`), then add a case here and set FACE_MATCH_PROVIDER.
 * Nothing in `verification.ts` needs to change.
 */
export function getFaceMatcher(): FaceMatcher {
  if (cached) return cached;

  switch (config.face.provider) {
    case 'mock':
      assertMockAllowed();
      cached = new MockFaceMatcher(new FirestoreTemplateStore());
      return cached;
    // case 'rekognition': cached = new RekognitionFaceMatcher(); return cached;
    // case 'azure':       cached = new AzureFaceMatcher();       return cached;
    // case 'compreface':  cached = new ComprefaceFaceMatcher();  return cached;
    default:
      throw new Error(`Unsupported FACE_MATCH_PROVIDER: ${config.face.provider}`);
  }
}

/** Refuse to boot with the fake matcher in a production project. */
function assertMockAllowed(): void {
  const allow = process.env.ALLOW_MOCK_FACE_MATCH === 'true';
  const projectId =
    process.env.GCLOUD_PROJECT ?? process.env.GOOGLE_CLOUD_PROJECT ?? '';
  const looksProd = /prod/i.test(projectId);
  if (looksProd && !allow) {
    throw new Error(
      'MockFaceMatcher refused: project looks like production. ' +
        'Set FACE_MATCH_PROVIDER to a real vendor, or ALLOW_MOCK_FACE_MATCH=true to override.',
    );
  }
}

/** Test seam. */
export function __setFaceMatcher(matcher: FaceMatcher | null): void {
  cached = matcher;
}
