import { describe, expect, it } from 'vitest';
import type { Product } from '../types/catalog';
import { scoreAssistantProduct } from './assistantProductScorer';
import { normalizeAssistantText } from './assistantTextNormalizer';

const product: Product = {
  id: 22,
  sourceId: 'perceuse-source-only',
  reference: 'REF-0022',
  name: 'Armoire d’atelier',
  shortDescription: 'Armoire à portes battantes pour organiser le matériel.',
  familyCode: 'FAM-RAN',
  familyLabel: 'Rangement',
  brand: 'Novatool',
  imageUrl: null,
  sourceUpdatedAtUtc: '2026-08-05T08:15:00Z',
};

describe('assistant product scorer', () => {
  it('never scores SourceId', () => {
    const result = scoreAssistantProduct(product, normalizeAssistantText('perceuse'));

    expect(result.score).toBe(0);
    expect(result.matchedConceptIds).toEqual([]);
  });

  it('gives brand matches a strong weight only for an explicit brand request', () => {
    const implicit = scoreAssistantProduct(product, normalizeAssistantText('Novatool'));
    const explicit = scoreAssistantProduct(product, normalizeAssistantText('marque Novatool'));

    expect(implicit.score).toBe(3);
    expect(explicit.score).toBe(12);
  });
});
