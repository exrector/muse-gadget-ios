import { env } from "cloudflare:workers";

const MAX_BODY_BYTES = 256 * 1024;
const MAX_REPORTS_PER_HOUR = 60;
const RETENTION_DAYS = 30;
const ALLOWED_KINDS = new Set(["metrickit_crash", "metrickit_hang", "manual"]);

type Breadcrumb = { at: string; event: string; detail?: string };
type ReportEnvelope = {
  schemaVersion: number;
  reportID: string;
  sentAt: string;
  appVersion: string;
  build: string;
  platform: "ios" | "ipados";
  osVersion: string;
  model: string;
  locale: string;
  testFlight: boolean;
  kind: "metrickit_crash" | "metrickit_hang" | "manual";
  reason?: string;
  diagnostic: unknown;
  breadcrumbs: Breadcrumb[];
};

function json(value: unknown, status = 200): Response {
  return Response.json(value, {
    status,
    headers: {
      "cache-control": "no-store",
      "content-type": "application/json; charset=utf-8",
      "x-content-type-options": "nosniff",
    },
  });
}

function boundedString(value: unknown, max: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= max;
}

function validISODate(value: unknown): value is string {
  return boundedString(value, 40) && !Number.isNaN(Date.parse(value));
}

function validUUID(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function validateReport(value: unknown): ReportEnvelope | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const report = value as Record<string, unknown>;
  if (report.schemaVersion !== 1 || !validUUID(report.reportID)) return null;
  if (!validISODate(report.sentAt) || !boundedString(report.appVersion, 32) || !boundedString(report.build, 24)) return null;
  if (report.platform !== "ios" && report.platform !== "ipados") return null;
  if (!boundedString(report.osVersion, 32) || !boundedString(report.model, 64) || !boundedString(report.locale, 32)) return null;
  if (typeof report.testFlight !== "boolean" || typeof report.kind !== "string" || !ALLOWED_KINDS.has(report.kind)) return null;
  if (report.reason !== undefined && (typeof report.reason !== "string" || report.reason.length > 512)) return null;
  if (!Array.isArray(report.breadcrumbs) || report.breadcrumbs.length > 100) return null;
  for (const item of report.breadcrumbs) {
    if (!item || typeof item !== "object" || Array.isArray(item)) return null;
    const crumb = item as Record<string, unknown>;
    if (!validISODate(crumb.at) || !boundedString(crumb.event, 64)) return null;
    if (crumb.detail !== undefined && (typeof crumb.detail !== "string" || crumb.detail.length > 160)) return null;
  }
  const diagnosticSize = new TextEncoder().encode(JSON.stringify(report.diagnostic ?? {})).byteLength;
  if (diagnosticSize > 192 * 1024) return null;
  return report as ReportEnvelope;
}

async function digestHex(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function authorized(request: Request): Promise<boolean> {
  const provided = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "";
  if (!provided || !env.ADMIN_TOKEN) return false;
  const [actualHash, expectedHash] = await Promise.all([digestHex(provided), digestHex(env.ADMIN_TOKEN)]);
  let difference = actualHash.length ^ expectedHash.length;
  const length = Math.max(actualHash.length, expectedHash.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (actualHash.charCodeAt(index) || 0) ^ (expectedHash.charCodeAt(index) || 0);
  }
  return difference === 0;
}

async function withinRateLimit(request: Request): Promise<boolean> {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const key = await digestHex(`${env.IP_HASH_SALT}:${ip}`);
  const now = Math.floor(Date.now() / 1000);
  const existing = await env.DB.prepare("SELECT window_start, count FROM rate_limits WHERE key = ?")
    .bind(key).first<{ window_start: number; count: number }>();
  if (!existing || now - existing.window_start >= 3600) {
    await env.DB.prepare(
      "INSERT INTO rate_limits(key, window_start, count) VALUES (?, ?, 1) ON CONFLICT(key) DO UPDATE SET window_start = excluded.window_start, count = 1"
    ).bind(key, now).run();
    return true;
  }
  if (existing.count >= MAX_REPORTS_PER_HOUR) return false;
  await env.DB.prepare("UPDATE rate_limits SET count = count + 1 WHERE key = ?").bind(key).run();
  return true;
}

async function ingest(request: Request, context: ExecutionContext): Promise<Response> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);
  const raw = await request.arrayBuffer();
  if (raw.byteLength > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);
  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const report = validateReport(decoded);
  if (!report) return json({ error: "invalid_report" }, 400);
  if (!(await withinRateLimit(request))) return json({ error: "rate_limited" }, 429);

  const result = await env.DB.prepare(
    `INSERT OR IGNORE INTO reports
      (id, installation_id, received_at, sent_at, app_version, build, platform, os_version, model, locale, testflight, kind, reason, payload_json, breadcrumbs_json)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).bind(
    report.reportID,
    "",
    new Date().toISOString(),
    report.sentAt,
    report.appVersion,
    report.build,
    report.platform,
    report.osVersion,
    report.model,
    report.locale,
    report.testFlight ? 1 : 0,
    report.kind,
    report.reason ?? null,
    JSON.stringify(report.diagnostic ?? {}),
    JSON.stringify(report.breadcrumbs)
  ).run();

  context.waitUntil(env.DB.batch([
    env.DB.prepare("DELETE FROM reports WHERE received_at < datetime('now', ?)").bind(`-${RETENTION_DAYS} days`),
    env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?").bind(Math.floor(Date.now() / 1000) - 172800),
  ]));
  console.log(JSON.stringify({ event: "report_ingested", id: report.reportID, kind: report.kind, inserted: result.meta.changes === 1 }));
  return json({ accepted: true, duplicate: result.meta.changes !== 1 }, 202);
}

async function listReports(url: URL): Promise<Response> {
  const requested = Number(url.searchParams.get("limit") ?? "50");
  const limit = Number.isFinite(requested) ? Math.min(100, Math.max(1, Math.floor(requested))) : 50;
  const result = await env.DB.prepare(
    `SELECT id, received_at, sent_at, app_version, build, platform, os_version, model, locale, testflight, kind, reason
     FROM reports ORDER BY received_at DESC LIMIT ?`
  ).bind(limit).all();
  return json({ reports: result.results });
}

async function getReport(id: string): Promise<Response> {
  if (!validUUID(id)) return json({ error: "invalid_id" }, 400);
  const report = await env.DB.prepare("SELECT * FROM reports WHERE id = ?").bind(id).first();
  return report ? json({ report }) : json({ error: "not_found" }, 404);
}

export default {
  async fetch(request, _env, context) {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true, service: "pal-again-diagnostics" });
    }
    if (request.method === "POST" && url.pathname === "/v1/reports") {
      return ingest(request, context);
    }
    if (url.pathname === "/v1/reports" || url.pathname.startsWith("/v1/reports/")) {
      if (!(await authorized(request))) return json({ error: "unauthorized" }, 401);
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      if (url.pathname === "/v1/reports") return listReports(url);
      return getReport(url.pathname.slice("/v1/reports/".length));
    }
    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler;

