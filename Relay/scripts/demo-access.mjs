import { randomBytes } from "node:crypto";
import { readFile, writeFile, rename, unlink, open, lstat } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { demoPrefix, tokenID, parseDemoConfig } from "../src/demo-access.js";

function positive(value, fallback, maximum = 365) {
  const number = Number(value ?? fallback);
  if (!Number.isInteger(number) || number < 1 || number > maximum) throw new Error("invalid number");
  return number;
}
// Updates a local config only. Upload its contents to DEMO_ACCESS_CONFIG to apply
// issuance, expiry extensions, revocations, or pause to the running Relay.
export async function runAdmin([command, configPath, ...args], report = console.log) {
  if (!["issue", "extend", "revoke", "enable", "disable", "status"].includes(command)
      || !configPath?.endsWith(".demo-config.json")) throw new Error("usage");
  const lock = await open(configPath + ".lock", "wx", 0o600);
  const temporary = configPath + "." + randomBytes(8).toString("hex") + ".tmp";
  try {
    let config;
    try {
      if (!(await lstat(configPath)).isFile()) throw new Error("not a regular file");
      config = parseDemoConfig(await readFile(configPath, "utf8"));
    } catch (error) {
      if (error.code !== "ENOENT" || command !== "issue") throw error;
      config = { enabled: false, credentials: {} };
    }
    let receipt;
    if (command === "issue") {
      const [endpoint, output, days, minute] = args;
      const url = new URL(endpoint);
      if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash
          || !output?.endsWith(".demo-access.json")) throw new Error("invalid configuration");
      const token = demoPrefix + randomBytes(32).toString("hex");
      const id = tokenID(token);
      const record = { expiresAt: Math.floor(Date.now() / 1000) + positive(days, 7) * 86400,
        minuteLimit: positive(minute, 5, 60), revoked: false };
      config.credentials[id] = record;
      parseDemoConfig(JSON.stringify(config));
      await writeFile(output, JSON.stringify({ endpoint: url.href, token }, null, 2), { mode: 0o600, flag: "wx" });
      receipt = { id, ...record, credentialFileCreated: true };
    } else if (["extend", "revoke"].includes(command)) {
      const [id, days] = args;
      if (!Object.hasOwn(config.credentials, id ?? "")) throw new Error("unknown id");
      if (command === "revoke") config.credentials[id].revoked = true;
      else config.credentials[id].expiresAt = Math.max(config.credentials[id].expiresAt, Math.floor(Date.now() / 1000)) + positive(days, 7) * 86400;
    } else if (command === "status") {
      report(JSON.stringify({ enabled: config.enabled, credentials: Object.keys(config.credentials).length }));
      return;
    } else { config.enabled = command === "enable"; }
    const serialized = JSON.stringify(config);
    parseDemoConfig(serialized);
    await writeFile(temporary, serialized + "\n", { mode: 0o600, flag: "wx" });
    await rename(temporary, configPath);
    report(JSON.stringify({ ...receipt, appliedToCloud: false, message: "本地配置已更新；同步到 Relay 的 DEMO_ACCESS_CONFIG 后生效。延期不恢复已撤销凭证。" }));
  } finally {
    await lock.close();
    await unlink(configPath + ".lock");
    await unlink(temporary).catch(() => {});
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { await runAdmin(process.argv.slice(2)); }
  catch {
    console.error("操作未完成，请检查配置文件、参数或锁文件。未输出凭证。\n用法：issue <配置.demo-config.json> <https地址> <新凭证.demo-access.json> [天数=7] [每分钟请求=5] | extend <配置> <id> [天数=7] | revoke <配置> <id> | enable <配置> | disable <配置> | status <配置>");
    process.exitCode = 1;
  }
}
