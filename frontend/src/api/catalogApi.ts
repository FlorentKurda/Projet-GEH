import type {
  CatalogFiltersResponse,
  Product,
  ProductListResponse,
  ProductQuery,
} from '../types/catalog';
import type { CatalogClient } from './catalogClient';

export class CatalogApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
  ) {
    super(message);
    this.name = 'CatalogApiError';
  }
}

export function buildProductQuery(query: ProductQuery): string {
  const parameters = new URLSearchParams({
    page: String(query.page),
    per_page: String(query.perPage),
  });
  if (query.search) parameters.set('search', query.search);
  if (query.family) parameters.set('family', query.family);
  if (query.brand) parameters.set('brand', query.brand);
  return parameters.toString();
}

export function createCatalogApi(restBaseUrl: string): CatalogClient {
  const baseUrl = restBaseUrl.replace(/\/$/, '');

  async function request<T>(path: string, signal?: AbortSignal): Promise<T> {
    const response = await fetch(`${baseUrl}${path}`, {
      method: 'GET',
      headers: { Accept: 'application/json' },
      signal,
      credentials: 'same-origin',
    });

    if (!response.ok) {
      throw new CatalogApiError('Catalog API request failed.', response.status);
    }

    return (await response.json()) as T;
  }

  return {
    getProducts(query: ProductQuery, signal?: AbortSignal) {
      return request<ProductListResponse>(`/products?${buildProductQuery(query)}`, signal);
    },

    getProduct(id: number, signal?: AbortSignal) {
      return request<Product>(`/products/${encodeURIComponent(String(id))}`, signal);
    },

    getFilters(signal?: AbortSignal) {
      return request<CatalogFiltersResponse>('/filters', signal);
    },
  };
}
