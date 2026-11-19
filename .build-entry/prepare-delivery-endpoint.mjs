import { appendFileSync } from "node:fs"

const { cloudApi } = JSON.parse(process.env.ZHANLU_DELIVERY_BUILD_OPTIONS || "{}")
if (cloudApi !== undefined) {
  if (typeof cloudApi !== "string" || cloudApi.length > 2048 || /[\x00-\x20\x7f]/.test(cloudApi))
    throw new Error("Invalid delivery endpoint")
  const endpoint = new URL(cloudApi)
  if (endpoint.protocol !== "https:" || endpoint.username || endpoint.password || endpoint.search || endpoint.hash)
    throw new Error("Invalid delivery endpoint")
  appendFileSync(process.env.GITHUB_ENV, "ZL_DELIVERY_CLOUD_API=" + endpoint.href.replace(/\/+$/, "") + "\n")
}
