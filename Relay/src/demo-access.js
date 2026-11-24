import { createHash, randomUUID } from "node:crypto";

export const demoPrefix = "bx_demo_";
export function tokenID(token) {
  if (typeof token !== "string" || token.length !== 72 || !/^bx_demo_[a-f0-9]{64}$/.test(token)) throw new DemoAccessError("DEMO_INVALID", 401);
  return createHash("sha256").update(token).digest("hex");
}
export class DemoAccessError extends Error {
  constructor(code, statusCode = 503) {
    super(code);
    this.name = "DemoAccessError";
    this.code = code;
    this.statusCode = statusCode;
    this.noFallback = true;
  }
}

export function parseDemoConfig(raw) {
  try {
    if (typeof raw !== "string" || Buffer.byteLength(raw) > 32768) throw new Error();
    const config = JSON.parse(raw);
    if (!config || typeof config.enabled !== "boolean" || !config.credentials
      || typeof config.credentials !== "object" || Array.isArray(config.credentials)) throw new Error();
    const entries = Object.entries(config.credentials);
    if (entries.length > 100) throw new Error();
    for (const [id, record] of entries) {
      if (!/^[a-f0-9]{64}$/.test(id) || !record
        || !Number.isSafeInteger(record.expiresAt) || record.expiresAt <= 0
        || typeof record.revoked !== "boolean"
        || !Number.isInteger(record.minuteLimit) || record.minuteLimit < 1 || record.minuteLimit > 60) throw new Error();
    }
    return config;
  } catch { throw new DemoAccessError("DEMO_UNAVAILABLE"); }
}

// Shared by requests within this process only. Restart/scale-out resets or splits
// these counters: they are not a daily quota or an account-wide spending cap.
const processState = new Map();
export class DemoAccess {
  constructor({ env = process.env, state = processState, now = () => Date.now() } = {}) {
    this.env = env; this.state = state; this.now = now;
  }
  check(token) {
    const id = tokenID(token);
    const config = parseDemoConfig(this.env.DEMO_ACCESS_CONFIG);
    // Bound memory even after configuration replacement.
    for (const key of this.state.keys()) if (!Object.hasOwn(config.credentials, key)) this.state.delete(key);
    const record = config.credentials[id];
    if (!record) throw new DemoAccessError("DEMO_INVALID", 401);
    if (record.revoked) throw new DemoAccessError("DEMO_REVOKED", 401);
    if (record.expiresAt * 1000 <= this.now()) throw new DemoAccessError("DEMO_EXPIRED", 401);
    if (!config.enabled) throw new DemoAccessError("DEMO_DISABLED");
    return { id, record };
  }
  async status(token) {
    const { record } = this.check(token);
    return { expiresAt: record.expiresAt, limitScope: "process", requestsPerMinute: record.minuteLimit };
  }
  async acquire(token) {
    const { id, record } = this.check(token);
    const now = this.now();
    const minute = Math.floor(now / 60000);
    const current = this.state.get(id) ?? { minute, requests: 0, lease: null, leaseUntil: 0 };
    if (current.leaseUntil > now) throw new DemoAccessError("DEMO_BUSY", 429);
    if (current.minute !== minute) { current.minute = minute; current.requests = 0; }
    if (current.requests >= record.minuteLimit) throw new DemoAccessError("DEMO_RATE_LIMIT", 429);
    const lease = randomUUID();
    current.requests += 1;
    current.lease = lease;
    current.leaseUntil = now + 180000;
    this.state.set(id, current);
    let attempts = 0;
    return {
      consume: async () => {
        this.check(token);
        if (this.state.get(id)?.lease !== lease || current.leaseUntil <= this.now()) throw new DemoAccessError("DEMO_BUSY", 429);
        if (++attempts > 2) throw new DemoAccessError("DEMO_RATE_LIMIT", 429);
      },
      release: async () => {
        if (this.state.get(id)?.lease === lease) { current.lease = null; current.leaseUntil = 0; }
      },
    };
  }
}
