import type { CatalogClient } from './catalogClient';
import type {
  CatalogFiltersResponse,
  Product,
  ProductListResponse,
  ProductQuery,
} from '../types/catalog';

export const STATIC_CATALOG_SCHEMA_VERSION = 1;
const MAX_PRODUCTS_PER_PAGE = 24;
const MAX_SEARCH_LENGTH = 100;

export interface StaticCatalogDocument {
  schemaVersion: typeof STATIC_CATALOG_SCHEMA_VERSION;
  source: 'fixtures/products.json';
  products: Product[];
}

export class StaticCatalogError extends Error {
  constructor(
    message: string,
    public readonly status: number,
  ) {
    super(message);
    this.name = 'StaticCatalogError';
  }
}

export function createStaticCatalogClient(
  catalogUrl: string,
  fetcher: typeof fetch = fetch,
): CatalogClient {
  let productsPromise: Promise<Product[]> | null = null;

  const loadProducts = async (signal?: AbortSignal): Promise<Product[]> => {
    throwIfAborted(signal);
    if (!productsPromise) {
      productsPromise = fetcher(catalogUrl, {
        method: 'GET',
        headers: { Accept: 'application/json' },
        credentials: 'same-origin',
      })
        .then(async (response) => {
          if (!response.ok) {
            throw new StaticCatalogError('Static catalog request failed.', response.status);
          }
          const document: unknown = await response.json();
          if (!isStaticCatalogDocument(document)) {
            throw new StaticCatalogError('Static catalog document is invalid.', 500);
          }
          return document.products;
        })
        .catch((error: unknown) => {
          productsPromise = null;
          throw error;
        });
    }

    const products = await productsPromise;
    throwIfAborted(signal);
    return products;
  };

  return {
    async getProducts(query, signal) {
      const products = await loadProducts(signal);
      const filtered = filterProducts(products, query);
      const page = normalizePositiveInteger(query.page, 1);
      const perPage = Math.min(
        normalizePositiveInteger(query.perPage, MAX_PRODUCTS_PER_PAGE),
        MAX_PRODUCTS_PER_PAGE,
      );
      const totalItems = filtered.length;
      const totalPages = totalItems === 0 ? 0 : Math.ceil(totalItems / perPage);
      const offset = (page - 1) * perPage;

      return {
        items: filtered.slice(offset, offset + perPage),
        pagination: { page, perPage, totalItems, totalPages },
      } satisfies ProductListResponse;
    },

    async getProduct(id, signal) {
      const products = await loadProducts(signal);
      const product = products.find((candidate) => candidate.id === id);
      if (!product) throw new StaticCatalogError('Static catalog product was not found.', 404);
      return product;
    },

    async getFilters(signal) {
      const products = await loadProducts(signal);
      return buildFilters(products);
    },
  };
}

function filterProducts(products: readonly Product[], query: ProductQuery): Product[] {
  const search = normalizeForStaticSearch(query.search.slice(0, MAX_SEARCH_LENGTH));

  return products.filter((product) => {
    if (query.family && product.familyCode !== query.family) return false;
    if (query.brand && product.brand !== query.brand) return false;
    if (!search) return true;

    return [product.reference, product.name, product.brand, product.familyLabel]
      .filter((value): value is string => typeof value === 'string')
      .some((value) => normalizeForStaticSearch(value).includes(search));
  });
}

function buildFilters(products: readonly Product[]): CatalogFiltersResponse {
  const families = new Map<string, string>();
  const brands = new Set<string>();

  products.forEach((product) => {
    if (product.familyCode && product.familyLabel) {
      families.set(product.familyCode, product.familyLabel);
    }
    if (product.brand) brands.add(product.brand);
  });

  return {
    families: [...families].map(([code, label]) => ({ code, label })).sort((left, right) =>
      left.label.localeCompare(right.label, 'fr'),
    ),
    brands: [...brands].sort((left, right) => left.localeCompare(right, 'fr')),
  };
}

function normalizeForStaticSearch(value: string): string {
  return value
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLocaleLowerCase('fr')
    .trim();
}

function normalizePositiveInteger(value: number, fallback: number): number {
  return Number.isSafeInteger(value) && value >= 1 ? value : fallback;
}

function throwIfAborted(signal?: AbortSignal): void {
  if (!signal?.aborted) return;
  throw signal.reason instanceof Error
    ? signal.reason
    : new DOMException('The operation was aborted.', 'AbortError');
}

function isStaticCatalogDocument(value: unknown): value is StaticCatalogDocument {
  if (!isRecord(value)) return false;
  return (
    value.schemaVersion === STATIC_CATALOG_SCHEMA_VERSION &&
    value.source === 'fixtures/products.json' &&
    Array.isArray(value.products) &&
    value.products.every(isProduct)
  );
}

function isProduct(value: unknown): value is Product {
  if (!isRecord(value)) return false;
  return (
    typeof value.id === 'number' &&
    typeof value.sourceId === 'string' &&
    typeof value.reference === 'string' &&
    typeof value.name === 'string' &&
    isNullableString(value.shortDescription) &&
    isNullableString(value.familyCode) &&
    isNullableString(value.familyLabel) &&
    isNullableString(value.brand) &&
    isNullableString(value.imageUrl) &&
    isNullableString(value.sourceUpdatedAtUtc)
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isNullableString(value: unknown): value is string | null {
  return value === null || typeof value === 'string';
}
