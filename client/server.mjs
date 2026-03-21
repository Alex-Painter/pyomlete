import { serve } from "srvx/node";
import server from "./dist/server/server.js";

const port = parseInt(process.env.NITRO_PORT ?? process.env.PORT ?? "3000");
const host = process.env.HOST || "0.0.0.0";

serve({
  port,
  hostname: host,
  fetch: server.fetch,
});
