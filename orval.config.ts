import { defineConfig } from 'orval'

export default defineConfig({
  'profiler-gem': {
    input: './swagger/v1/swagger.yaml',
    output: {
      target: './app/assets/typescript/profiler/generated/api.ts',
      schemas: './app/assets/typescript/profiler/generated/schemas/',
      client: 'react-query',
      // orval 8 defaults to a fetch-style client: `apiFetch(url, RequestInit)` returning
      // `{ data, status, headers }`. The custom mutator takes orval 7's config object and
      // returns the body, so keep that shape.
      httpClient: 'axios',
      override: {
        mutator: {
          path: './app/assets/typescript/profiler/api-fetcher.ts',
          name: 'apiFetch',
        },
        query: {
          // No global `useQuery: true`: from orval 8 on it turns every verb into a query,
          // POST and DELETE included. Left unset, GET gets a query and the rest a mutation,
          // which is what orval 7 generated with it.
          useInfinite: true,
          useInfiniteParam: 'offset',
          initialPageParam: 0,
        },
        operations: Object.fromEntries(
          [
            'getProfile', 'deleteProfile', 'clearProfiles',
            'getJob', 'deleteJob', 'clearJobs',
            'getConsole', 'deleteConsole', 'clearConsoles',
            'getTest', 'deleteTest', 'clearTests',
            'listOutboundRequests',
            'getEnvVars', 'updateEnvVar', 'resetEnvVar', 'resetAllEnvVars',
            'getEditorConfig', 'getFunctionProfiling', 'updateFunctionProfiling',
            'explainQuery',
            'getToolbar',
            'getTestRunnerFiles', 'createTestRun', 'getTestRun', 'deleteTestRun',
          ].map(id => [id, { query: { useInfinite: false } }])
        ),
      },
    },
  },
})
