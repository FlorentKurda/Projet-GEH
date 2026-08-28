import { describe, expect, it } from 'vitest';
import { buildProductQuery } from './catalogApi';

describe('product API query', () => {
  it('encodes pagination, search and filters', () => {
    const parameters = new URLSearchParams(
      buildProductQuery({
        page: 2,
        perPage: 24,
        search: 'mètre à ruban',
        family: 'FAM-MES',
        brand: 'Équinoxe',
      }),
    );
    expect(Object.fromEntries(parameters)).toEqual({
      page: '2',
      per_page: '24',
      search: 'mètre à ruban',
      family: 'FAM-MES',
      brand: 'Équinoxe',
    });
  });

  it('omits empty optional criteria', () => {
    expect(
      buildProductQuery({ page: 1, perPage: 24, search: '', family: '', brand: '' }),
    ).toBe('page=1&per_page=24');
  });
});
