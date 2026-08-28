import { describe, expect, it } from 'vitest';
import type { Product } from '../types/catalog';
import { getProductMetadata } from './productPresentation';

const product: Product = {
  id: 1,
  sourceId: 'MOCK-0001',
  reference: 'REF-0001',
  name: 'Produit',
  shortDescription: null,
  familyCode: 'FAM-A',
  familyLabel: 'Famille A',
  brand: 'Marque A',
  imageUrl: null,
  sourceUpdatedAtUtc: null,
};

describe('product presentation', () => {
  it('formats only available optional metadata', () => {
    expect(getProductMetadata(product)).toEqual(['Marque A', 'Famille A']);
    expect(getProductMetadata({ ...product, brand: null })).toEqual(['Famille A']);
    expect(getProductMetadata({ ...product, brand: null, familyLabel: null })).toEqual([]);
  });
});
