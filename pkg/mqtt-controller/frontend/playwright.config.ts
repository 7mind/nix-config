import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests', testMatch: '*.spec.ts', fullyParallel: false,
  use: { baseURL: 'http://127.0.0.1:18780', launchOptions: { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH } },
  webServer: { command: 'node tests/server.mjs', port: 18780, reuseExistingServer: false },
});
