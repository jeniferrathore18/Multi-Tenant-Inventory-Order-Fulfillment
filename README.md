# AetherStock - Multi-Tenant Inventory & Order Fulfillment System

AetherStock is an enterprise-grade Multi-Tenant Inventory & Order Fulfillment SaaS platform built on Next.js 16 App Router, Supabase, Tailwind CSS v4, and PostgreSQL. It enforces robust isolation, race-condition-free stock allocations, cross-warehouse inventory transfers, order fulfillment pipelines, background reconciliation crons, and dark/light responsive dashboards.

---

## Key Features

- **Multi-Tenant Architecture**: Complete tenant isolation at the database level using PostgreSQL Row-Level Security (RLS) policies.
- **Atomic Stock Reservation (Phase 9)**: Race-condition-free reservations ensuring overselling is impossible under high concurrency.
- **Scheduled Reconciliation (Phase 11)**: Background idempotent audits identifying drifts, low stock levels, and ledger sequencing anomalies.
- **Responsive Telemetry Dashboard (Phase 12)**: Dark/light interactive dashboards featuring SVG trend lines, warehouse comparison bar charts, and alert warnings.
- **Admin Management Panel (Phase 13)**: Workspace administration center for membership invitation, role customization, profile setup, and system logs.

---

## Tech Stack
- **Framework**: Next.js 16.2 App Router (React 19)
- **Styling**: Tailwind CSS v4 + Vanilla CSS theme switcher
- **Backend & Database**: Supabase SSR (Auth) & PostgreSQL 17 (RLS + PL/pgSQL Stored Procedures)
- **Validation**: Zod Schemas

---

## Getting Started

### 1. Prerequisites
- Node.js 20+
- A Supabase Cloud or local Docker database instance.

### 2. Environment Variables Configuration
Duplicate `.env.example` as `.env.local` and configure:
```env
NEXT_PUBLIC_SUPABASE_URL=https://your-project-id.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-supabase-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-supabase-service-role-key
DATABASE_URL=postgresql://postgres:password@db-host:port/postgres
CRON_SECRET=your-secure-cron-webhook-secret-token
```

### 3. Apply Schema Migrations
Apply the PostgreSQL migration files to your database:
```bash
psql $DATABASE_URL -f database/schema.sql
psql $DATABASE_URL -f database/schema_phase5_8.sql
psql $DATABASE_URL -f database/schema_phase9_12.sql
```

### 4. Running the Development Server
Install dependencies and run Next.js dev server:
```bash
npm install
npm run dev
```

### 5. Running Concurrency Simulations
To verify atomic reservations and verify locks:
```bash
npx tsx scripts/simulate-concurrency.ts
```
Outputs a detailed `concurrency_report.md` auditing concurrency runs.
