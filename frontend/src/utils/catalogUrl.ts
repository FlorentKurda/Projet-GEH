export interface CatalogLocationState {
  search: string;
  family: string;
  brand: string;
  page: number;
  productId: number | null;
}

const catalogKeys = ['search', 'family', 'brand', 'page', 'product'] as const;

export const defaultCatalogLocation: CatalogLocationState = {
  search: '',
  family: '',
  brand: '',
  page: 1,
  productId: null,
};

export function parseCatalogSearch(search: string): CatalogLocationState {
  const parameters = new URLSearchParams(search);
  const page = parsePositiveInteger(parameters.get('page')) ?? 1;
  const productId = parsePositiveInteger(parameters.get('product'));

  return {
    search: (parameters.get('search') ?? '').trim(),
    family: (parameters.get('family') ?? '').trim(),
    brand: (parameters.get('brand') ?? '').trim(),
    page,
    productId,
  };
}

export function buildCatalogSearch(
  state: CatalogLocationState,
  currentSearch = '',
): string {
  const parameters = new URLSearchParams(currentSearch);
  catalogKeys.forEach((key) => parameters.delete(key));

  if (state.search) parameters.set('search', state.search);
  if (state.family) parameters.set('family', state.family);
  if (state.brand) parameters.set('brand', state.brand);
  if (state.page > 1) parameters.set('page', String(state.page));
  if (state.productId !== null) parameters.set('product', String(state.productId));

  const value = parameters.toString();
  return value ? `?${value}` : '';
}

export function writeCatalogLocation(
  state: CatalogLocationState,
  mode: 'push' | 'replace',
): void {
  const search = buildCatalogSearch(state, window.location.search);
  const url = `${window.location.pathname}${search}${window.location.hash}`;
  const method = mode === 'push' ? 'pushState' : 'replaceState';
  window.history[method](null, '', url);
}

function parsePositiveInteger(value: string | null): number | null {
  if (value === null || !/^\d+$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 1 ? parsed : null;
}
