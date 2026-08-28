import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { createCatalogApi } from './api/catalogApi';
import { FilterBar } from './components/FilterBar';
import { LoadingGrid } from './components/LoadingGrid';
import { Pagination } from './components/Pagination';
import { ProductCard } from './components/ProductCard';
import { ProductDetail } from './components/ProductDetail';
import { useDebouncedCallback } from './hooks/useDebouncedCallback';
import type {
  CatalogFiltersResponse,
  CatalogRuntimeConfig,
  Product,
  ProductListResponse,
} from './types/catalog';
import {
  parseCatalogSearch,
  writeCatalogLocation,
  type CatalogLocationState,
} from './utils/catalogUrl';

const emptyFilters: CatalogFiltersResponse = { families: [], brands: [] };

interface AppProps {
  config: CatalogRuntimeConfig;
}

export function App({ config }: AppProps) {
  const api = useMemo(() => createCatalogApi(config.restBaseUrl), [config.restBaseUrl]);
  const rootRef = useRef<HTMLElement>(null);
  const openedFromListRef = useRef(false);
  const [location, setLocation] = useState<CatalogLocationState>(() =>
    parseCatalogSearch(window.location.search),
  );
  const [searchInput, setSearchInput] = useState(location.search);
  const [result, setResult] = useState<ProductListResponse | null>(null);
  const [filters, setFilters] = useState<CatalogFiltersResponse>(emptyFilters);
  const [filtersLoading, setFiltersLoading] = useState(true);
  const [filtersError, setFiltersError] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [detail, setDetail] = useState<Product | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState(false);
  const [retryToken, setRetryToken] = useState(0);

  const applySearch = useCallback((value: string) => {
    const search = value.trim();
    setLocation((current) => {
      if (current.search === search && current.page === 1 && current.productId === null) {
        return current;
      }
      const next = { ...current, search, page: 1, productId: null };
      writeCatalogLocation(next, 'replace');
      return next;
    });
  }, []);
  const debouncedSearch = useDebouncedCallback(applySearch, 350);

  useEffect(() => {
    const controller = new AbortController();
    setFiltersLoading(true);
    setFiltersError(false);
    api
      .getFilters(controller.signal)
      .then(setFilters)
      .catch((requestError: unknown) => {
        if (requestError instanceof DOMException && requestError.name === 'AbortError') return;
        console.error('Catalog filters could not be loaded.', requestError);
        setFiltersError(true);
      })
      .finally(() => {
        if (!controller.signal.aborted) setFiltersLoading(false);
      });
    return () => controller.abort();
  }, [api, retryToken]);

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    setError(false);
    api
      .getProducts(
        {
          page: location.page,
          perPage: config.perPage,
          search: location.search,
          family: location.family,
          brand: location.brand,
        },
        controller.signal,
      )
      .then((response) => {
        if (response.pagination.totalPages > 0 && location.page > response.pagination.totalPages) {
          setLocation((current) => {
            const next = { ...current, page: response.pagination.totalPages };
            writeCatalogLocation(next, 'replace');
            return next;
          });
          return;
        }
        setResult(response);
      })
      .catch((requestError: unknown) => {
        if (requestError instanceof DOMException && requestError.name === 'AbortError') return;
        console.error('Catalog products could not be loaded.', requestError);
        setError(true);
      })
      .finally(() => {
        if (!controller.signal.aborted) setLoading(false);
      });
    return () => controller.abort();
  }, [
    api,
    config.perPage,
    location.page,
    location.search,
    location.family,
    location.brand,
    retryToken,
  ]);

  useEffect(() => {
    if (location.productId === null) {
      setDetail(null);
      setDetailError(false);
      setDetailLoading(false);
      return;
    }

    const controller = new AbortController();
    setDetail(null);
    setDetailError(false);
    setDetailLoading(true);
    api
      .getProduct(location.productId, controller.signal)
      .then(setDetail)
      .catch((requestError: unknown) => {
        if (requestError instanceof DOMException && requestError.name === 'AbortError') return;
        console.error('Catalog product detail could not be loaded.', requestError);
        setDetailError(true);
      })
      .finally(() => {
        if (!controller.signal.aborted) setDetailLoading(false);
      });
    return () => controller.abort();
  }, [api, location.productId, retryToken]);

  useEffect(() => {
    const handlePopState = () => {
      debouncedSearch.cancel();
      const next = parseCatalogSearch(window.location.search);
      setLocation(next);
      setSearchInput(next.search);
      if (next.productId === null) openedFromListRef.current = false;
    };
    window.addEventListener('popstate', handlePopState);
    return () => window.removeEventListener('popstate', handlePopState);
  }, [debouncedSearch.cancel]);

  const updateListCriteria = useCallback(
    (changes: Partial<CatalogLocationState>) => {
      debouncedSearch.cancel();
      setLocation((current) => {
        const next = {
          ...current,
          search: searchInput.trim(),
          ...changes,
          page: 1,
          productId: null,
        };
        writeCatalogLocation(next, 'push');
        return next;
      });
    },
    [debouncedSearch.cancel, searchInput],
  );

  const handlePageChange = (page: number) => {
    setLocation((current) => {
      const next = { ...current, page, productId: null };
      writeCatalogLocation(next, 'push');
      return next;
    });
    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    rootRef.current?.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' });
  };

  const handleOpenProduct = (product: Product) => {
    openedFromListRef.current = true;
    setLocation((current) => {
      const next = { ...current, productId: product.id };
      writeCatalogLocation(next, 'push');
      return next;
    });
  };

  const handleBack = () => {
    if (openedFromListRef.current) {
      openedFromListRef.current = false;
      window.history.back();
      return;
    }
    setLocation((current) => {
      const next = { ...current, productId: null };
      writeCatalogLocation(next, 'replace');
      return next;
    });
  };

  const handleReset = () => {
    debouncedSearch.cancel();
    setSearchInput('');
    updateListCriteria({ search: '', family: '', brand: '' });
  };

  if (location.productId !== null) {
    return (
      <section className="geh-catalog" ref={rootRef} aria-label="Fiche produit">
        {detailLoading && <div className="geh-catalog-detail-loading">Chargement du produit…</div>}
        {detailError && (
          <div className="geh-catalog-notice geh-catalog-notice--error" role="alert">
            <p>Impossible de charger ce produit pour le moment.</p>
            <div className="geh-catalog-notice__actions">
              <button type="button" onClick={() => setRetryToken((value) => value + 1)}>
                Réessayer
              </button>
              <button type="button" onClick={handleBack}>Retour aux produits</button>
            </div>
          </div>
        )}
        {detail && (
          <ProductDetail
            product={detail}
            placeholderUrl={config.placeholderUrl}
            onBack={handleBack}
          />
        )}
      </section>
    );
  }

  return (
    <section className="geh-catalog" ref={rootRef} aria-labelledby="geh-catalog-title">
      <header className="geh-catalog-header">
        <p className="geh-catalog-eyebrow">Nos produits</p>
        <h1 id="geh-catalog-title">Catalogue produits</h1>
        <p>Découvrez notre sélection et affinez les résultats par famille ou par marque.</p>
      </header>

      <FilterBar
        searchInput={searchInput}
        family={location.family}
        brand={location.brand}
        filters={filters}
        filtersLoading={filtersLoading}
        onSearchChange={(value) => {
          setSearchInput(value);
          debouncedSearch.schedule(value);
        }}
        onFamilyChange={(family) => updateListCriteria({ family })}
        onBrandChange={(brand) => updateListCriteria({ brand })}
        onReset={handleReset}
      />

      {filtersError && (
        <p className="geh-catalog-filter-warning" role="status">
          Les filtres sont temporairement indisponibles. La recherche reste utilisable.
        </p>
      )}

      {loading && !result && <LoadingGrid />}
      {error && (
        <div className="geh-catalog-notice geh-catalog-notice--error" role="alert">
          <p>Impossible de charger les produits pour le moment.</p>
          <button type="button" onClick={() => setRetryToken((value) => value + 1)}>
            Réessayer
          </button>
        </div>
      )}

      {!error && result && (
        <>
          <div className="geh-catalog-results-heading" aria-live="polite">
            <p>
              <strong>{result.pagination.totalItems}</strong>{' '}
              {result.pagination.totalItems > 1 ? 'produits trouvés' : 'produit trouvé'}
            </p>
            {loading && <span>Actualisation…</span>}
          </div>

          {result.items.length === 0 ? (
            <div className="geh-catalog-notice geh-catalog-notice--empty">
              <h2>Aucun produit ne correspond à votre recherche.</h2>
              <p>Modifiez vos critères ou réinitialisez les filtres.</p>
              <button type="button" onClick={handleReset}>Réinitialiser les filtres</button>
            </div>
          ) : (
            <div className={`geh-catalog-grid${loading ? ' is-updating' : ''}`}>
              {result.items.map((product) => (
                <ProductCard
                  key={product.id}
                  product={product}
                  placeholderUrl={config.placeholderUrl}
                  onOpen={handleOpenProduct}
                />
              ))}
            </div>
          )}

          <Pagination
            page={result.pagination.page}
            totalPages={result.pagination.totalPages}
            onChange={handlePageChange}
          />
        </>
      )}
    </section>
  );
}
