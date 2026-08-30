import { describe, expect, it, vi } from 'vitest';
import type { CatalogClient } from '../api/catalogClient';
import type { Product } from '../types/catalog';
import {
  ASSISTANT_CANDIDATE_LIMIT_PER_QUERY,
  createAssistantCatalogSearch,
} from './assistantCatalogSearch';

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

describe('assistant catalog search', () => {
  it('reuses the public catalog client for bounded queries and merges duplicates', async () => {
    const getProducts = vi.fn(async () => ({
      items: [product],
      pagination: {
        page: 1,
        perPage: ASSISTANT_CANDIDATE_LIMIT_PER_QUERY,
        totalItems: 1,
        totalPages: 1,
      },
    }));
    const api = {
      getProducts,
      getProduct: vi.fn(),
      getFilters: vi.fn(),
    } as unknown as CatalogClient;

    await expect(
      createAssistantCatalogSearch(api)(['perceuse', 'outillage', 'perceuse']),
    ).resolves.toEqual([product]);
    expect(getProducts).toHaveBeenCalledTimes(2);
    expect(getProducts).toHaveBeenNthCalledWith(
      1,
      {
        page: 1,
        perPage: ASSISTANT_CANDIDATE_LIMIT_PER_QUERY,
        search: 'perceuse',
        family: '',
        brand: '',
      },
      undefined,
    );
  });

  it('never calls the API for empty or shorter-than-three-character searches', async () => {
    const getProducts = vi.fn();
    const api = {
      getProducts,
      getProduct: vi.fn(),
      getFilters: vi.fn(),
    } as unknown as CatalogClient;

    await expect(
      createAssistantCatalogSearch(api)([' ', 'd', 'ab', "'", '---']),
    ).resolves.toEqual([]);
    expect(getProducts).not.toHaveBeenCalled();
  });
});
