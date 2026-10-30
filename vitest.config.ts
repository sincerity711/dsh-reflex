import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['test/**/*.spec.ts'],
    restoreMocks: true,
    testTimeout: 20000,
  },
})
