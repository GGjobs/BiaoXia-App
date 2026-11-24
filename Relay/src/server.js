import { createServer } from "node:http";
import { handler } from "./index.js";

const port = Number(process.env.PORT ?? 8787);
createServer((req, res) => handler(req, res)).listen(port, () => {
  console.info(`BiaoXia relay listening on http://127.0.0.1:${port}`);
});
