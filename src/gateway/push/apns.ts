import crypto from "node:crypto";
import fs from "node:fs/promises";
import http2 from "node:http2";

type ApnsEnv = "sandbox" | "production";

export type ApnsProviderConfig = {
  env: ApnsEnv;
  teamId: string;
  keyId: string;
  topic: string;
  privateKeyPem: string;
};

function base64url(input: Buffer | string): string {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input, "utf8");
  return buf.toString("base64").replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function nowSec() {
  return Math.floor(Date.now() / 1000);
}

let cachedJwt: { token: string; iat: number; key: string } | null = null;

function cacheKey(cfg: ApnsProviderConfig) {
  // Private key changes should invalidate the cache. Keep it cheap by hashing metadata only.
  const keyHash = crypto.createHash("sha256").update(cfg.privateKeyPem).digest("hex").slice(0, 12);
  return `${cfg.teamId}:${cfg.keyId}:${keyHash}`;
}

export function makeApnsJwt(cfg: ApnsProviderConfig): string {
  const iat = nowSec();
  const key = cacheKey(cfg);
  // Apple recommends rotating the token at most once per 20 minutes; keep a wider window.
  if (cachedJwt && cachedJwt.key === key && iat - cachedJwt.iat < 50 * 60) {
    return cachedJwt.token;
  }

  const header = { alg: "ES256", kid: cfg.keyId, typ: "JWT" };
  const claims = { iss: cfg.teamId, iat };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;

  const sign = crypto.createSign("SHA256");
  sign.update(signingInput);
  sign.end();
  const signature = sign.sign({ key: cfg.privateKeyPem, dsaEncoding: "ieee-p1363" });
  const token = `${signingInput}.${base64url(signature)}`;
  cachedJwt = { token, iat, key };
  return token;
}

export async function loadApnsPrivateKeyPem(opts: {
  keyPath?: string | null;
  keyPem?: string | null;
}): Promise<string> {
  if (opts.keyPem && opts.keyPem.trim()) {
    return opts.keyPem.trim();
  }
  if (opts.keyPath && opts.keyPath.trim()) {
    const raw = await fs.readFile(opts.keyPath.trim(), "utf8");
    return raw.trim();
  }
  throw new Error("missing APNs private key (set OPENCLAW_APNS_KEY_PATH or OPENCLAW_APNS_KEY_P8)");
}

export async function sendApnsPush(params: {
  cfg: ApnsProviderConfig;
  deviceToken: string;
  payload: unknown;
  pushType: "alert" | "background";
  priority: 10 | 5;
}): Promise<{ ok: boolean; status: number; apnsId?: string; responseBody?: string }> {
  const host =
    params.cfg.env === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
  const jwt = makeApnsJwt(params.cfg);
  const body = JSON.stringify(params.payload ?? {});

  const client = http2.connect(`https://${host}:443`);
  return await new Promise((resolve) => {
    client.on("error", (err) => {
      try {
        client.close();
      } catch {
        // ignore
      }
      resolve({ ok: false, status: 0, responseBody: String(err) });
    });

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${params.deviceToken}`,
      "content-type": "application/json",
      "apns-topic": params.cfg.topic,
      "apns-push-type": params.pushType,
      "apns-priority": String(params.priority),
      authorization: `bearer ${jwt}`,
    });

    let status = 0;
    let apnsId: string | undefined;
    let responseBody = "";

    req.setEncoding("utf8");
    req.on("response", (headers) => {
      status = Number(headers[":status"] ?? 0);
      apnsId = typeof headers["apns-id"] === "string" ? headers["apns-id"] : undefined;
    });
    req.on("data", (chunk) => {
      responseBody += String(chunk);
    });
    req.on("end", () => {
      try {
        client.close();
      } catch {
        // ignore
      }
      resolve({
        ok: status >= 200 && status < 300,
        status,
        apnsId,
        responseBody: responseBody.trim() ? responseBody.trim() : undefined,
      });
    });
    req.on("error", (err) => {
      try {
        client.close();
      } catch {
        // ignore
      }
      resolve({ ok: false, status: status || 0, apnsId, responseBody: String(err) });
    });

    req.end(body);
  });
}
