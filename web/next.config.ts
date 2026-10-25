import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Self-contained server.js + traced node_modules, for a small Docker image.
  output: "standalone",
  cacheComponents: true,
  partialPrefetching: true,
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
