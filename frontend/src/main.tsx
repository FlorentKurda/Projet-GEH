import { createRoot } from 'react-dom/client';
import { App } from './App';
import { createCatalogApi } from './api/catalogApi';
import type { CatalogClient } from './api/catalogClient';
import { createStaticCatalogClient } from './api/staticCatalogClient';
import type { CatalogDisplayConfig, CatalogRuntimeConfig } from './types/catalog';
import './styles.css';

interface AppRuntime {
  config: CatalogDisplayConfig;
  client: CatalogClient;
  demo: boolean;
}

const runtime = createAppRuntime();
const roots = document.querySelectorAll<HTMLElement>('.geh-catalog-root');

roots.forEach((element) => {
  if (!runtime) {
    element.textContent = 'Le catalogue est temporairement indisponible.';
    return;
  }
  createRoot(element).render(
    <App config={runtime.config} client={runtime.client} demo={runtime.demo} />,
  );
});

function createAppRuntime(): AppRuntime | null {
  if (import.meta.env.MODE === 'demo') {
    const baseUrl = import.meta.env.BASE_URL;
    return {
      config: {
        placeholderUrl: `${baseUrl}assets/product-placeholder.svg`,
        perPage: 24,
      },
      client: createStaticCatalogClient(`${baseUrl}catalog.json`),
      demo: true,
    };
  }

  const config = getWordPressRuntimeConfig();
  if (!config) return null;
  return {
    config,
    client: createCatalogApi(config.restBaseUrl),
    demo: false,
  };
}

function getWordPressRuntimeConfig(): CatalogRuntimeConfig | undefined {
  if (window.GEH_CATALOG_CONFIG) return window.GEH_CATALOG_CONFIG;
  if (!import.meta.env.DEV) return undefined;

  return {
    restBaseUrl: '/wp-json/catalog/v1',
    placeholderUrl:
      '/wp-content/plugins/product-catalog-sync/assets/images/product-placeholder.svg',
    perPage: 24,
  };
}
