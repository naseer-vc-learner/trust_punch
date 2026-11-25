import * as jpeg from 'jpeg-js';
import { describe, expect, it } from 'vitest';
import { config } from '../src/config';
import {
  InMemoryTemplateStore,
  MockFaceMatcher,
  featureVector,
  similarity,
} from '../src/faceMatch/MockFaceMatcher';

/**
 * Real JPEGs, synthesised so the tests never depend on photos of actual people.
 *
 * Each "face" is a distinct arrangement of light and dark regions, which is
 * what the matcher compares. `variant` nudges brightness and position slightly
 * to stand in for the same person photographed twice.
 */
function faceJpeg(
  personSeed: number,
  { variant = 0, width = 160, height = 160 } = {},
): Buffer {
  const data = Buffer.alloc(width * height * 4);
  const rand = (n: number) => {
    let x = (personSeed * 7919 + n * 104729) & 0x7fffffff;
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    return (x % 1000) / 1000;
  };

  // Three blobs whose positions/sizes are determined by the person seed.
  const blobs = [0, 1, 2].map((i) => ({
    cx: 0.2 + rand(i * 3) * 0.6,
    cy: 0.2 + rand(i * 3 + 1) * 0.6,
    r: 0.12 + rand(i * 3 + 2) * 0.18,
  }));

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const nx = x / width;
      const ny = y / height;
      let v = 60 + variant * 12; // background, shifted by lighting variant
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
  return jpeg.encode({ data, width, height }, 92).data;
}

describe('the bug this replaced', () => {
  it('scores two different people well apart, not at 1.0', () => {
    // The byte-histogram version returned 1.0000 here, so every employee
    // matched every face. This is the regression guard for that.
    const a = featureVector(faceJpeg(1))!;
    const b = featureVector(faceJpeg(42))!;
    const score = similarity(a, b);

    expect(score).toBeLessThan(config.face.approveThreshold);
  });
});

describe('MockFaceMatcher — identity binding', () => {
  it('matches the enrolled person', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    const { embeddingRef } = await matcher.enroll('emp_1', [
      faceJpeg(1, { variant: 0 }),
      faceJpeg(1, { variant: 1 }),
      faceJpeg(1, { variant: 2 }),
      faceJpeg(1, { variant: 3 }),
      faceJpeg(1, { variant: 4 }),
    ]);

    const result = await matcher.match(embeddingRef, faceJpeg(1, { variant: 1 }));
    expect(result.faceFound).toBe(true);
    expect(result.score).toBeGreaterThanOrEqual(config.face.approveThreshold);
  });

  it('REJECTS a different person against that enrollment', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    const { embeddingRef } = await matcher.enroll(
      'emp_1',
      [0, 1, 2, 3, 4].map((v) => faceJpeg(1, { variant: v })),
    );

    // The exact scenario found in testing: enroll one face, present another.
    const result = await matcher.match(embeddingRef, faceJpeg(42));
    expect(result.score).toBeLessThan(config.face.reviewThreshold);
  });

  it('keeps two employees distinguishable', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    const alice = await matcher.enroll(
      'alice',
      [0, 1, 2, 3, 4].map((v) => faceJpeg(7, { variant: v })),
    );
    const bob = await matcher.enroll(
      'bob',
      [0, 1, 2, 3, 4].map((v) => faceJpeg(99, { variant: v })),
    );

    const aliceOnAlice = await matcher.match(alice.embeddingRef, faceJpeg(7, { variant: 2 }));
    const bobOnAlice = await matcher.match(alice.embeddingRef, faceJpeg(99, { variant: 2 }));

    expect(aliceOnAlice.score).toBeGreaterThan(bobOnAlice.score + 0.15);
    expect(bob.embeddingRef).not.toBe(alice.embeddingRef);
  });
});

describe('duplicate detection at enrollment', () => {
  it('finds an existing employee with the same face', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    await matcher.enroll('ali', [0, 1, 2, 3, 4].map((v) => faceJpeg(5, { variant: v })));

    // The same person now tries to enroll as somebody else.
    const dupes = await matcher.findDuplicates(faceJpeg(5, { variant: 1 }), {
      excludeEmployeeId: 'sam',
      threshold: config.face.duplicateThreshold,
    });

    expect(dupes).toHaveLength(1);
    expect(dupes[0].employeeId).toBe('ali');
    expect(dupes[0].score).toBeGreaterThanOrEqual(config.face.duplicateThreshold);
  });

  it('does not flag a genuinely different new hire', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    await matcher.enroll('ali', [0, 1, 2, 3, 4].map((v) => faceJpeg(5, { variant: v })));

    const dupes = await matcher.findDuplicates(faceJpeg(500), {
      excludeEmployeeId: 'newhire',
      threshold: config.face.duplicateThreshold,
    });
    expect(dupes).toEqual([]);
  });

  it('excludes the employee re-enrolling themselves', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    await matcher.enroll('ali', [0, 1, 2, 3, 4].map((v) => faceJpeg(5, { variant: v })));

    const dupes = await matcher.findDuplicates(faceJpeg(5), {
      excludeEmployeeId: 'ali',
      threshold: config.face.duplicateThreshold,
    });
    expect(dupes).toEqual([]);
  });

  it('returns the strongest match first', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    await matcher.enroll('exact', [0, 1, 2, 3, 4].map((v) => faceJpeg(11, { variant: v })));
    await matcher.enroll('other', [0, 1, 2, 3, 4].map((v) => faceJpeg(12, { variant: v })));

    const dupes = await matcher.findDuplicates(faceJpeg(11), {
      threshold: 0.0,
    });
    expect(dupes[0].employeeId).toBe('exact');
    expect(dupes[0].score).toBeGreaterThan(dupes[1].score);
  });
});

describe('input handling', () => {
  it('reports faceFound=false for an undecodable buffer', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    const { embeddingRef } = await matcher.enroll(
      'emp_1',
      [0, 1, 2, 3, 4].map((v) => faceJpeg(1, { variant: v })),
    );

    const result = await matcher.match(embeddingRef, Buffer.from([0xff, 0xd8, 0xff, 0x00]));
    expect(result.faceFound).toBe(false);
    expect(result.score).toBe(0);
  });

  it('refuses to enroll when nothing decodes', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    await expect(matcher.enroll('emp_1', [Buffer.alloc(0)])).rejects.toThrow();
  });

  it('throws on an unknown ref rather than defaulting to a score', async () => {
    const matcher = new MockFaceMatcher(new InMemoryTemplateStore());
    await expect(matcher.match('mock:nope', faceJpeg(1))).rejects.toThrow();
  });

  it('erases the template on deleteEnrollment', async () => {
    const store = new InMemoryTemplateStore();
    const matcher = new MockFaceMatcher(store);
    const { embeddingRef } = await matcher.enroll(
      'emp_1',
      [0, 1, 2, 3, 4].map((v) => faceJpeg(1, { variant: v })),
    );

    await matcher.deleteEnrollment(embeddingRef);
    expect(await store.get(embeddingRef)).toBeNull();
    expect(await store.listAll()).toEqual([]);
  });
});

describe('featureVector', () => {
  it('is contrast-normalised, so overall brightness does not dominate', () => {
    const v = featureVector(faceJpeg(3))!;
    const mean = v.reduce((a, b) => a + b, 0) / v.length;
    expect(Math.abs(mean)).toBeLessThan(1e-6);
  });

  it('is resolution independent', () => {
    const small = featureVector(faceJpeg(3, { width: 80, height: 80 }))!;
    const large = featureVector(faceJpeg(3, { width: 320, height: 320 }))!;
    expect(similarity(small, large)).toBeGreaterThan(0.95);
  });

  it('returns null rather than throwing on non-image bytes', () => {
    expect(featureVector(Buffer.from('not an image'))).toBeNull();
  });
});
