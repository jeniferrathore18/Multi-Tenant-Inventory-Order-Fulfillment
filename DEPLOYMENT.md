# Production Deployment Handbook - AetherStock

This guide details steps required to deploy AetherStock on **Vercel** (Frontend / API Routes) and **Supabase** (Database + Row Level Security).

---

## 1. Supabase Cloud Database Deployment

### Schema DDL Migration
Apply the database scripts to your Supabase SQL Editor in sequence:
1. **[schema.sql](file:///Users/jeniferrathore/PROJECT%201/database/schema.sql)**: Installs base tenant memberships, profiles sync trigger, warehouses, and product catalogs.
2. **[schema_phase5_8.sql](file:///Users/jeniferrathore/PROJECT%201/database/schema_phase5_8.sql)**: Installs inventory balances, immutable stock movement timeline logs, transfer history, customer orders, and transaction procedures (`adjust_stock`, `transfer_stock`, `fulfill_order`).
3. **[schema_phase9_12.sql](file:///Users/jeniferrathore/PROJECT%201/database/schema_phase9_12.sql)**: Installs stock allocations, scheduled reports, drift tracking flags, and concurrent-safe RPC procedures (`reserve_stock`, `release_stock`, `fulfill_reservation`).

---

## 2. Vercel Hosting Deployment

1. Go to [Vercel](https://vercel.com/new).
2. Import this repository folder.
3. Configure the **Environment Variables** in project settings:

| Variable | Scope | Purpose |
| :--- | :--- | :--- |
| `NEXT_PUBLIC_SUPABASE_URL` | Public / Frontend | Supabase API cloud endpoint URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Public / Frontend | Supabase anonymous access key |
| `SUPABASE_SERVICE_ROLE_KEY` | Private / Secure | Service bypass token for reconciliation cron |
| `CRON_SECRET` | Private / Secure | Webhook auth token verifying Vercel Cron requests |
| `NEXTAUTH_SECRET` | Private / Secure | Standard authentication session encryption key |

4. Click **Deploy**. Vercel will build the Next.js bundle and expose the optimized site URL.

---

## 3. Configuring Scheduled Reconciliation Cron

Configure Vercel Cron by adding `vercel.json` in your repository root, mapping the idempotent API route endpoint `/api/cron/reconcile`:

```json
{
  "crons": [
    {
      "path": "/api/cron/reconcile",
      "schedule": "0 0 * * *"
    }
  ]
}
```
This triggers the reconciliation audit every night at midnight UTC to flag product inventory drifts, low-stock warning thresholds, and movement sequence errors.
