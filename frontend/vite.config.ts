import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { Plugin } from 'vite';
import { defineConfig } from 'vitest/config';

const fixturePath = fileURLToPath(new URL('../fixtures/products.json', import.meta.url));
const placeholderPath = fileURLToPath(
  new URL(
    '../wordpress/product-catalog-sync/assets/images/product-placeholder.svg',
    import.meta.url,
  ),
);

export default defineConfig(({ command, mode }) => {
  const demo = mode === 'demo';

  return {
    base: demo ? '/Projet-GEH/' : '/',
    plugins: demo ? [createDemoAssetsPlugin()] : [],
    define: {
      'process.env.NODE_ENV': JSON.stringify(
        command === 'build' ? 'production' : 'development',
      ),
    },
    server: demo
      ? undefined
      : {
          proxy: {
            '/wp-json': 'http://localhost:8080',
            '/wp-content': 'http://localhost:8080',
          },
        },
    build: demo
      ? {
          outDir: 'dist-demo',
          emptyOutDir: true,
        }
      : {
          outDir: '../wordpress/product-catalog-sync/assets/dist',
          emptyOutDir: true,
          lib: {
            entry: 'src/main.tsx',
            name: 'GEHProductCatalog',
            formats: ['iife'],
            fileName: () => 'catalog.js',
            cssFileName: 'catalog',
          },
        },
    test: {
      include: ['src/**/*.test.ts', 'src/**/*.test.tsx'],
    },
  };
});

function createDemoAssetsPlugin(): Plugin {
  return {
    name: 'geh-demo-assets',
    apply: 'build',
    generateBundle() {
      const fixtures = JSON.parse(readFileSync(fixturePath, 'utf8')) as Array<
        Record<string, unknown>
      >;
      const products = fixtures.map((product, index) => ({
        ...product,
        id: index + 1,
        imageUrl: null,
      }));

      this.emitFile({
        type: 'asset',
        fileName: 'catalog.json',
        source: `${JSON.stringify(
          {
            schemaVersion: 1,
            source: 'fixtures/products.json',
            products,
          },
          null,
          2,
        )}\n`,
      });
      this.emitFile({
        type: 'asset',
        fileName: 'assets/product-placeholder.svg',
        source: readFileSync(placeholderPath),
      });
    },
  };
}
