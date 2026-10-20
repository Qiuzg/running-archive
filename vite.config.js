import { defineConfig, loadEnv } from "vite";
import { fileURLToPath } from "node:url";

const BASE_PATH = process.env.BASE_PATH || "/";
const BASE_PREFIX = BASE_PATH === "/" ? "" : BASE_PATH.replace(/\/$/, "");

export default defineConfig({
  base: BASE_PATH,
  define: {
    "import.meta.env.VITE_BASE": JSON.stringify(BASE_PREFIX),
  },
  server: {
    port: 5173,
    proxy: {
      [`${BASE_PREFIX}/api`]: {
        target: process.env.RUNNING_API_TARGET || loadEnv("development", process.cwd(), "RUNNING_").RUNNING_API_TARGET || "http://127.0.0.1:8000",
        changeOrigin: true,
        rewrite: path => BASE_PREFIX ? path.slice(BASE_PREFIX.length) : path,
      },
    },
  },
  build: {
    outDir: "dist",
    assetsDir: "assets",
    rollupOptions: {
      input: {
        archive: fileURLToPath(new URL("./index.html", import.meta.url)),
        app: fileURLToPath(new URL("./app.html", import.meta.url)),
        journal: fileURLToPath(new URL("./journal.html", import.meta.url)),
      },
      output: {
        manualChunks: {
          chartjs: ["chart.js"],
        },
      },
    },
  },
  publicDir: "assets",
});
