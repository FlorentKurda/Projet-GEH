export interface Product {
  id: number;
  sourceId: string;
  reference: string;
  name: string;
  shortDescription: string | null;
  familyCode: string | null;
  familyLabel: string | null;
  brand: string | null;
  imageUrl: string | null;
  sourceUpdatedAtUtc: string | null;
}

export interface Pagination {
  page: number;
  perPage: number;
  totalItems: number;
  totalPages: number;
}

export interface ProductListResponse {
  items: Product[];
  pagination: Pagination;
}

export interface ProductFamily {
  code: string;
  label: string;
}

export interface CatalogFiltersResponse {
  families: ProductFamily[];
  brands: string[];
}

export interface ProductQuery {
  page: number;
  perPage: number;
  search: string;
  family: string;
  brand: string;
}

export interface CatalogRuntimeConfig {
  restBaseUrl: string;
  placeholderUrl: string;
  perPage: number;
}

export type CatalogDisplayConfig = Pick<
  CatalogRuntimeConfig,
  'placeholderUrl' | 'perPage'
>;

declare global {
  interface Window {
    GEH_CATALOG_CONFIG?: CatalogRuntimeConfig;
  }
}
