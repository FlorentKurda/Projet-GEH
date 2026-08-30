import { describe, expect, it } from 'vitest';
import { buildCatalogHref, buildCatalogSearch, parseCatalogSearch } from './catalogUrl';

describe('catalog URL state', () => {
  it('parses valid criteria and rejects invalid page identifiers', () => {
    expect(parseCatalogSearch('?search=perceuse&family=FAM-OUT&brand=Novatool&page=2&product=18'))
      .toEqual({
        search: 'perceuse',
        family: 'FAM-OUT',
        brand: 'Novatool',
        page: 2,
        productId: 18,
      });
    expect(parseCatalogSearch('?page=-2&product=abc').page).toBe(1);
    expect(parseCatalogSearch('?page=-2&product=abc').productId).toBeNull();
  });

  it('builds a shareable URL while preserving unrelated WordPress parameters', () => {
    const result = buildCatalogSearch(
      { search: 'clé plate', family: 'FAM-OUT', brand: '', page: 3, productId: null },
      '?utm_source=test&product=99',
    );
    const parameters = new URLSearchParams(result);
    expect(parameters.get('utm_source')).toBe('test');
    expect(parameters.get('search')).toBe('clé plate');
    expect(parameters.get('family')).toBe('FAM-OUT');
    expect(parameters.get('page')).toBe('3');
    expect(parameters.has('product')).toBe(false);
  });

  it('omits empty criteria and the first page', () => {
    expect(buildCatalogSearch({ search: '', family: '', brand: '', page: 1, productId: null }))
      .toBe('');
  });

  it('keeps GitHub Pages navigation on the repository base path', () => {
    const href = buildCatalogHref(
      { search: '', family: '', brand: '', page: 1, productId: 51 },
      { pathname: '/Projet-GEH/', search: '', hash: '' },
    );

    expect(href).toBe('/Projet-GEH/?product=51');
    expect(parseCatalogSearch(new URL(href, 'https://example.test').search).productId).toBe(51);
  });
});
