import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: { proxy: { '/ws': { target: 'ws://127.0.0.1:8780', ws: true } } },
  test: { include: ['src/**/*.test.ts'] },
});
