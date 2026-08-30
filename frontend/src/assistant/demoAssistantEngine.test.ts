import { describe, expect, it, vi } from 'vitest';
import type { Product } from '../types/catalog';
import {
  buildAssistantRetrievalQueries,
  normalizeAssistantText,
} from './assistantTextNormalizer';
import { createDemoAssistantEngine } from './demoAssistantEngine';

const product: Product = {
  id: 51,
  sourceId: 'MOCK-0051',
  reference: 'REF-0051',
  name: 'Perceuse sans fil',
  shortDescription: 'Perceuse compacte avec réglage du couple.',
  familyCode: 'FAM-ELE',
  familyLabel: 'Outillage électroportatif',
  brand: 'Novatool',
  imageUrl: null,
  sourceUpdatedAtUtc: '2026-08-13T08:00:00Z',
};

const cleaningProduct: Product = {
  id: 27,
  sourceId: 'MOCK-0027',
  reference: 'REF-0027',
  name: 'Balai d’atelier',
  shortDescription: 'Balai large pour le nettoyage des sols durs.',
  familyCode: 'FAM-ENT',
  familyLabel: 'Entretien',
  brand: 'Boréal',
  imageUrl: null,
  sourceUpdatedAtUtc: '2026-08-07T08:00:00Z',
};

describe('demo assistant engine', () => {
  it('extracts a product keyword and returns only catalog results', async () => {
    const search = vi.fn(async (queries: readonly string[]) =>
      queries.includes('perceuse') ? [product] : [],
    );
    const engine = createDemoAssistantEngine(search);

    const reply = await engine.respond({
      text: 'Je cherche une perceuse',
      history: [],
    });

    expect(search).toHaveBeenCalledWith(['perceuse'], undefined);
    expect(reply.kind).toBe('results');
    expect(reply.products).toEqual([product]);
  });

  it('maps cleaning and floor concepts to bounded catalog queries', async () => {
    const search = vi.fn(async () => [cleaningProduct]);
    const engine = createDemoAssistantEngine(search);

    await engine.respond({
      text: 'Je veux nettoyer du carrelage',
      history: [],
    });

    expect(search).toHaveBeenCalledWith(
      ['entretien', 'nettoyage', 'sol', 'carrelage'],
      undefined,
    );
  });

  it('asks one clarification question for a vague request without querying the API', async () => {
    const search = vi.fn(async (_queries: readonly string[]) => [] as Product[]);
    const reply = await createDemoAssistantEngine(search).respond({
      text: 'Je cherche du matériel',
      history: [],
    });

    expect(reply).toEqual({
      kind: 'clarification',
      text: 'Pour quel usage ou quelle famille de produit ?',
    });
    expect(search).not.toHaveBeenCalled();
  });

  it('returns a clear no-result response with all useful concepts in one retrieval', async () => {
    const search = vi.fn(async (_queries: readonly string[]) => [] as Product[]);
    const reply = await createDemoAssistantEngine(search).respond({
      text: 'Je cherche une perceuse violette',
      history: [],
    });

    expect(search).toHaveBeenCalledWith(['perceuse', 'violette'], undefined);
    expect(reply.kind).toBe('no-results');
    expect(reply.products).toBeUndefined();
    expect(reply.text).toContain('pas trouvé de produit suffisamment proche');
  });

  it('rejects a candidate that does not match a significant qualifier', async () => {
    const search = vi.fn(async () => [product]);
    const reply = await createDemoAssistantEngine(search).respond({
      text: 'Je cherche une perceuse violette',
      history: [],
    });

    expect(reply.kind).toBe('no-results');
    expect(reply.products).toBeUndefined();
  });

  it('keeps references and explicit brand names as deterministic search concepts', () => {
    const normalized = normalizeAssistantText('La marque Novatool REF-0051');
    expect(buildAssistantRetrievalQueries(normalized)).toEqual(['novatool', 'ref-0051']);
    expect(normalized.brandRequested).toBe(true);
  });
});
