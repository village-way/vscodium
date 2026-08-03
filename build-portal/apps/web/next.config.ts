import type { NextConfig } from "next";
const config: NextConfig = { output: "standalone", poweredByHeader: false, experimental: { externalDir: true } };
export default config;
