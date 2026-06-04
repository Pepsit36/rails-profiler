import { defineConfig } from 'orval'

export default defineConfig({
  'profiler-gem': {
    input: './swagger/v1/swagger.yaml',
    output: {
      target: './app/assets/typescript/profiler/generated/api.ts',
      schemas: './app/assets/typescript/profiler/generated/schemas/',
      client: 'react-query',
      override: {
        mutator: {
          path: './app/assets/typescript/profiler/api-fetcher.ts',
          name: 'apiFetch',
        },
        query: {
          useQuery: true,
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
            'getFunctionProfiling', 'updateFunctionProfiling',
            'explainQuery',
            'getToolbar',
            'getTestRunnerFiles', 'createTestRun', 'getTestRun', 'deleteTestRun',
          ].map(id => [id, { query: { useInfinite: false } }])
        ),
      },
    },
  },
})
