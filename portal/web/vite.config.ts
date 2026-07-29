import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"
import { tanstackRouter } from "@tanstack/router-plugin/vite"

/**
 * In production nginx serves this bundle and proxies /api to the Hono API on loopback, so the
 * client uses a relative base and needs no host configuration. The dev server has no nginx in
 * front of it, so it proxies the same paths itself - otherwise `bun run dev` hits Vite for
 * /api/* and gets index.html back with a 200, which surfaces as a JSON parse error rather than
 * as "there is no API here".
 *
 * VITE_API_PROXY points it at an API on a different host or port.
 */
const API_TARGET = process.env.VITE_API_PROXY ?? "http://127.0.0.1:3000"

export default defineConfig({
  plugins: [
    tanstackRouter({
      target: "react",
      autoCodeSplitting: true,
    }),
    react(),
  ],
  server: {
    proxy: {
      "/api": { target: API_TARGET, changeOrigin: true },
      "/health": { target: API_TARGET, changeOrigin: true },
    },
  },
  preview: {
    proxy: {
      "/api": { target: API_TARGET, changeOrigin: true },
      "/health": { target: API_TARGET, changeOrigin: true },
    },
  },
})
