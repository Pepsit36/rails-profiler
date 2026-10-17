import { defineConfig } from 'vitest/config'

// Component and module tests of the Preact toolbar. The Node test runner keeps the plain
// JavaScript ones (spec/javascript/*.test.mjs).
export default defineConfig({
  // Vite 8 transforms JSX with oxc: told to use Preact.
  oxc: { jsx: { runtime: 'automatic', importSource: 'preact' } },
  resolve: {
    alias: { '@tanstack/react-query': '@tanstack/preact-query' },
  },
  test: {
    environment: 'jsdom',
    include: ['spec/javascript/**/*.spec.{ts,tsx}'],
  },
})
