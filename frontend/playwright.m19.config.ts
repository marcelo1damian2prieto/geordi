import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  retries: 0,
  reporter: 'list',
  outputDir: process.env.GEORDI_M19_BROWSER_SENTINEL_FILE
    ? process.env.GEORDI_M19_BROWSER_SENTINEL_FILE.replace(/[\\/][^\\/]+$/, '/playwright-output')
    : undefined,
  timeout: 30_000,
  use: {
    baseURL: process.env.M19_BROWSER_BASE_URL ?? 'https://geordi.localhost:8443',
    browserName: 'chromium',
    launchOptions: {
      args: ['--host-resolver-rules=MAP geordi.localhost 127.0.0.1,MAP auth.localhost 127.0.0.1:9445'],
    },
    ignoreHTTPSErrors: false,
    trace: 'off',
    video: 'off',
    screenshot: 'off',
  },
})
