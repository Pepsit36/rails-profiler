import { defineConfig } from 'vitest/config'

// Component and module tests of the Preact toolbar. The Node test runner keeps the plain
// JavaScript ones (spec/javascript/*.test.mjs).
export default defineConfig({
  esbuild: { jsx: 'automatic', jsxImportSource: 'preact' },
  resolve: {
    alias: { '@tanstack/react-query': '@tanstack/preact-query' },
  },
  test: {
    environment: 'jsdom',
    include: ['spec/javascript/**/*.spec.{ts,tsx}'],
  },
})
