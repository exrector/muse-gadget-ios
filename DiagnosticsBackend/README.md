# Pal Again diagnostics

Small Cloudflare Worker + D1 receiver for opt-in TestFlight crash diagnostics.

It accepts only a bounded schema containing MetricKit crash or hang data and safe app-flow breadcrumbs. Chat text, SDK/device tokens, filenames, photos, audio, account details and the gadget name are not collected. Reports expire after 30 days. Public ingestion is rate-limited; reading reports requires the private `ADMIN_TOKEN` Worker secret.

## Operations

```sh
npm install
cf build
cf deploy
```

Apply D1 migrations with the current database UUID from `cloudflare.config.ts`:

```sh
cf d1 migrations apply DATABASE_UUID --dir migrations
```

Set `ADMIN_TOKEN` and `IP_HASH_SALT` as Worker secrets. Never put either value in this repository.

