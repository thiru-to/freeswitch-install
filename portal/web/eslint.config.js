import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from 'typescript-eslint'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  // routeTree.gen.ts is written by the TanStack Router plugin on every build.
  globalIgnores(['dist', 'src/routeTree.gen.ts']),
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      tseslint.configs.recommended,
      reactHooks.configs.flat.recommended,
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      globals: globals.browser,
    },
  },
  {
    /*
     * TanStack Router's file-route convention requires each route module to export a `Route`
     * object alongside its components, which react-refresh/only-export-components forbids by
     * construction. The rule cannot be satisfied without abandoning file routes, so leaving it
     * on just means `bun run lint` is permanently red and stops being a signal anyone reads.
     */
    files: ['src/routes/**/*.tsx'],
    rules: { 'react-refresh/only-export-components': 'off' },
  },
])
