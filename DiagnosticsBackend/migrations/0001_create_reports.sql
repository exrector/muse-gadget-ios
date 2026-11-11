CREATE TABLE IF NOT EXISTS reports (
  id TEXT PRIMARY KEY,
  installation_id TEXT NOT NULL,
  received_at TEXT NOT NULL,
  sent_at TEXT NOT NULL,
  app_version TEXT NOT NULL,
  build TEXT NOT NULL,
  platform TEXT NOT NULL,
  os_version TEXT NOT NULL,
  model TEXT NOT NULL,
  locale TEXT NOT NULL,
  testflight INTEGER NOT NULL,
  kind TEXT NOT NULL,
  reason TEXT,
  payload_json TEXT NOT NULL,
  breadcrumbs_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS reports_received_at ON reports(received_at DESC);
CREATE INDEX IF NOT EXISTS reports_build_kind ON reports(build, kind, received_at DESC);

CREATE TABLE IF NOT EXISTS rate_limits (
  key TEXT PRIMARY KEY,
  window_start INTEGER NOT NULL,
  count INTEGER NOT NULL
);

