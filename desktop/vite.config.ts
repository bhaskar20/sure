import { defineConfig } from "vite";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// package.json sets "type": "module", so this config loads as ESM where
// __dirname is undefined; derive it from import.meta.url instead.
const rootDir = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    // The bundled runtime and native build folders hold thousands of files
    // (gems, PostgreSQL, Rust output) that are not part of this frontend.
    watch: { ignored: ["**/runtime/**", "**/build/**", "**/src-tauri/**"] },
  },
  build: {
    target: "safari15",
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: {
        main: resolve(rootDir, "index.html"),
        prefs: resolve(rootDir, "prefs.html"),
        bridge: resolve(rootDir, "src/bridge.ts"),
      },
      output: {
        entryFileNames: (chunk) => (chunk.name === "bridge" ? "bridge.js" : "assets/[name]-[hash].js"),
        format: "es",
      },
    },
  },
});
