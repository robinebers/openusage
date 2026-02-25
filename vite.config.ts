import path from "path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;

// https://vite.dev/config/
export default defineConfig(async () => ({
  plugins: [react(), tailwindcss()],

  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },

  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    include: ["src/**/*.test.{ts,tsx}", "plugins/**/*.test.js"],
    exclude: ["**/node_modules/**", "**/src-tauri/target/**"],
    clearMocks: true,
    mockReset: true,
    restoreMocks: true,
    coverage: {
      provider: "v8",
      include: ["src/**/*.{ts,tsx}", "plugins/**/*.js"],
      exclude: [
        "**/*.d.ts",
        "**/*.css",
        "public/**",
        "scripts/**",
        "src-tauri/**",
        "src-tauri/resources/**",
        "src-tauri/icons/**",
        // Test-only helpers (not production code)
        "plugins/test-helpers.js",
        // Entry point bootstrap (side-effect heavy, hard to unit test)
        "src/main.tsx",
        // SSR guard branch untestable in jsdom
        "src/hooks/use-dark-mode.ts",
      ],
      reporter: ["text", "html", "lcov"],
      thresholds: {
        perFile: false,
        branches: 90,
        lines: 90,
        functions: 90,
        statements: 90,
      },
    },
  },

  // Vite options tailored for Tauri development and only applied in `tauri dev` or `tauri build`
  //
  // 1. prevent Vite from obscuring rust errors
  clearScreen: false,
  // 2. tauri expects a fixed port, fail if that port is not available
  server: {
    port: 1420,
    strictPort: true,
    host: host || false,
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      // 3. tell Vite to ignore watching `src-tauri`
      ignored: ["**/src-tauri/**"],
    },
  },
}));
