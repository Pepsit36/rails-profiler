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
    coverage: {
      provider: 'v8',
      // Hand-written sources only: the orval client is regenerated on every run and not committed.
      include: ['app/assets/typescript/**/*.{ts,tsx}'],
      exclude: ['app/assets/typescript/profiler/generated/**'],
      reporter: ['text-summary', 'text'],
      // Measured: 3.48 statements, 2.29 branches, 3.2 functions, 3.79 lines. Floors sit just under.
      thresholds: { statements: 3, branches: 2, functions: 3, lines: 3 },
    },
  },
})
