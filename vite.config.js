import { defineConfig } from "vite";

const BASE_PATH = process.env.BASE_PATH || "/";

export default defineConfig({
  base: BASE_PATH,
  define: {
    "import.meta.env.VITE_BASE": JSON.stringify(BASE_PATH === "/" ? "" : BASE_PATH.replace(/\/$/, "")),
  },
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8000",
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: "dist",
    assetsDir: "assets",
    rollupOptions: {
      output: {
        manualChunks: {
          chartjs: ["chart.js"],
        },
      },
    },
  },
  publicDir: "assets",
});
