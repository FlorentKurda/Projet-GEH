import type {
  CatalogFiltersResponse,
  Product,
  ProductListResponse,
  ProductQuery,
} from '../types/catalog';

export interface CatalogClient {
  getProducts(query: ProductQuery, signal?: AbortSignal): Promise<ProductListResponse>;
  getProduct(id: number, signal?: AbortSignal): Promise<Product>;
  getFilters(signal?: AbortSignal): Promise<CatalogFiltersResponse>;
}
