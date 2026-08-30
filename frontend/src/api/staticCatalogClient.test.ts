import { describe, expect, it, vi } from 'vitest';
import fixtureProducts from '../../../fixtures/products.json';
import { createAssistantCatalogSearch } from '../assistant/assistantCatalogSearch';
import { createDemoAssistantEngine } from '../assistant/demoAssistantEngine';
import type { Product, ProductQuery } from '../types/catalog';
import {
  createStaticCatalogClient,
  STATIC_CATALOG_SCHEMA_VERSION,
  type StaticCatalogDocument,
} from './staticCatalogClient';

const products: Product[] = fixtureProducts.map((product, index) => ({
  ...product,
  id: index + 1,
  imageUrl: null,
}));

const document: StaticCatalogDocument = {
  schemaVersion: STATIC_CATALOG_SCHEMA_VERSION,
  source: 'fixtures/products.json',
  products,
};

describe('static catalog client', () => {
  it('loads the fixture once and paginates at 24 products per page', async () => {
    const { client, fetcher } = createClient();

    const firstPage = await client.getProducts(query());
    const thirdPage = await client.getProducts(query({ page: 3 }));

    expect(firstPage.items).toHaveLength(24);
    expect(firstPage.pagination).toEqual({
      page: 1,
      perPage: 24,
      totalItems: 60,
      totalPages: 3,
    });
    expect(thirdPage.items).toHaveLength(12);
    expect(fetcher).toHaveBeenCalledTimes(1);
    expect(fetcher).toHaveBeenCalledWith('/Projet-GEH/catalog.json', {
      method: 'GET',
      headers: { Accept: 'application/json' },
      credentials: 'same-origin',
    });
  });

  it('searches the same public fields without requiring WordPress', async () => {
    const { client } = createClient();
    const response = await client.getProducts(query({ search: 'perceuse' }));

    expect(response.items.map(({ name }) => name)).toEqual(['Perceuse sans fil']);
  });

  it('filters by family', async () => {
    const { client } = createClient();
    const response = await client.getProducts(query({ family: 'FAM-ENT' }));

    expect(response.items.length).toBeGreaterThan(0);
    expect(response.items.every(({ familyCode }) => familyCode === 'FAM-ENT')).toBe(true);
  });

  it('filters by brand', async () => {
    const { client } = createClient();
    const response = await client.getProducts(query({ brand: 'Novatool' }));

    expect(response.items.length).toBeGreaterThan(0);
    expect(response.items.every(({ brand }) => brand === 'Novatool')).toBe(true);
  });

  it('derives filters from the fixture and loads a product detail', async () => {
    const { client } = createClient();

    const filters = await client.getFilters();
    const detail = await client.getProduct(51);

    expect(filters.families).toContainEqual({ code: 'FAM-ELE', label: 'Outillage électroportatif' });
    expect(filters.brands).toContain('Novatool');
    expect(detail.name).toBe('Perceuse sans fil');
  });

  it('returns a typed 404 for an unknown detail', async () => {
    const { client } = createClient();

    await expect(client.getProduct(999)).rejects.toMatchObject({
      name: 'StaticCatalogError',
      status: 404,
    });
  });

  it('powers the demo assistant entirely from the static fixture', async () => {
    const { client } = createClient();
    const engine = createDemoAssistantEngine(createAssistantCatalogSearch(client));

    const reply = await engine.respond({ text: 'Je cherche une perceuse', history: [] });

    expect(reply.kind).toBe('results');
    expect(reply.products?.[0]?.name).toBe('Perceuse sans fil');
  });
});

function createClient() {
  const fetcher = vi.fn(async () =>
    new Response(JSON.stringify(document), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }),
  );
  return {
    client: createStaticCatalogClient('/Projet-GEH/catalog.json', fetcher),
    fetcher,
  };
}

function query(overrides: Partial<ProductQuery> = {}): ProductQuery {
  return {
    page: 1,
    perPage: 24,
    search: '',
    family: '',
    brand: '',
    ...overrides,
  };
}
