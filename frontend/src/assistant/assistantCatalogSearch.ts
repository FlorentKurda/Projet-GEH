import type { CatalogApi } from '../api/catalogApi';
import type { AssistantCatalogSearch } from './types';

export const ASSISTANT_CANDIDATE_LIMIT_PER_QUERY = 12;
export const ASSISTANT_MAX_QUERY_COUNT = 8;
export const ASSISTANT_MAX_CANDIDATES = 48;
const PUBLIC_API_SEARCH_LIMIT = 100;
const MIN_PUBLIC_API_SEARCH_LENGTH = 3;

export function createAssistantCatalogSearch(api: CatalogApi): AssistantCatalogSearch {
  return async (queries, signal) => {
    const searches = [
      ...new Set(
        queries
          .map((query) => query.trim().slice(0, PUBLIC_API_SEARCH_LIMIT))
          .filter(
            (query) =>
              query.replace(/[^\p{L}\p{N}]/gu, '').length >=
              MIN_PUBLIC_API_SEARCH_LENGTH,
          ),
      ),
    ].slice(0, ASSISTANT_MAX_QUERY_COUNT);
    if (searches.length === 0) return [];

    const responses = await Promise.all(
      searches.map((search) =>
        api.getProducts(
          {
            page: 1,
            perPage: ASSISTANT_CANDIDATE_LIMIT_PER_QUERY,
            search,
            family: '',
            brand: '',
          },
          signal,
        ),
      ),
    );
    const candidates = new Map<number, (typeof responses)[number]['items'][number]>();
    responses.forEach(({ items }) => {
      items.forEach((product) => {
        if (candidates.size < ASSISTANT_MAX_CANDIDATES || candidates.has(product.id)) {
          candidates.set(product.id, product);
        }
      });
    });

    return [...candidates.values()];
  };
}
