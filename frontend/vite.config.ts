import { defineConfig } from 'vitest/config';

export default defineConfig(({ command }) => ({
  define: {
    'process.env.NODE_ENV': JSON.stringify(command === 'build' ? 'production' : 'development'),
  },
  server: {
    proxy: {
      '/wp-json': 'http://localhost:8080',
      '/wp-content': 'http://localhost:8080',
    },
  },
  build: {
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
}));
