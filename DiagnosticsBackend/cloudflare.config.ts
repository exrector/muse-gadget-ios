import { bindings, defineConfig } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };

export default defineConfig({
  worker: {
    name: "pal-again-diagnostics",
    compatibilityDate: "2026-11-11",
    entrypoint,
    env: {
      DB: bindings.d1({
        name: "pal-again-diagnostics",
        id: "fa1393e9-31bc-414a-893e-3dde564366b1",
      }),
      ADMIN_TOKEN: bindings.secret(),
      IP_HASH_SALT: bindings.secret(),
    },
    observability: {
      enabled: true,
      logs: { enabled: true, headSamplingRate: 1 },
      traces: { enabled: true, headSamplingRate: 0.01 },
    },
  },
});

