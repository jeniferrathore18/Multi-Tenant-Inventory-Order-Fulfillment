# Technical Architecture Design - AetherStock

This document outlines AetherStock's multi-tenant database isolation model, directory hierarchy, transaction safety patterns, and concurrent stock allocation algorithms.

---

## 1. Directory Structure

AetherStock utilizes a scalable, type-safe Next.js enterprise directory layout:

```yaml
PROJECT 1/
├── database/                # Schema DDL migration scripts & PG stored procedures
├── actions/                 # Server Actions orchestrating DB RPC calls and caching
├── app/                     # Next.js App Router (Authenticated vs Auth routes)
│   ├── (authenticated)/     # Pages protected by Supabase SSR auth route middleware
│   │   ├── dashboard/       # Premium responsive telemetry analytics
│   │   ├── inventory/       # Stock balances & adjust forms
│   │   ├── movements/       # Immutable audit timeline ledger
│   │   ├── orders/          # Sales invoicing & fulfillment panel
│   │   ├── reservations/    # Booking allocations
│   │   ├── transfers/       # Cross-warehouse balance movement logs
│   │   └── warehouses/      # Physical locationCRUD
│   └── api/                 # Cron endpoints & REST API routes
├── components/              # UI widgets, layout navbars, and interactive modals
├── lib/                     # Database server/client constructors & validation schemas
└── scripts/                 # CLI concurrency simulation runner scripts
```

---

## 2. Multi-Tenant RLS Isolation Architecture

Isolation is enforced directly inside the PostgreSQL layer using **Row-Level Security (RLS) policies**. Every data table contains a `tenant_id` foreign key referencing the tenant organization.

Access is dynamically validated by evaluating active user membership inside `tenant_memberships` in every policy:

```sql
CREATE POLICY "Users can select inventory of their tenants" ON public.inventory
  FOR SELECT USING (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid()
    )
  );
```
Supabase client calls run under the authenticated user's JWT context, making tenant data leakage between workspaces mathematically impossible.

---

## 3. Transaction Boundaries & Atomic Operations

To prevent double debiting, inventory drift, and race conditions, business logic runs inside **PostgreSQL stored procedures (PL/pgSQL RPCs)** executed as single database transactions:

### 1. Stock Adjustment (`adjust_stock`)
- Updates or inserts inventory, checks constraints, and logs movements. All updates roll back automatically on negative balance exceptions.

### 2. Stock Transfer (`transfer_stock`)
- Debits the source warehouse and credits the destination warehouse inside an atomic block. Prevents inventory skew where stock could be debited but not credited.

### 3. Fulfilling Orders (`fulfill_order`)
- Locks pending orders via `FOR UPDATE`, checks unreserved stock levels for all nested order items, and decrements balances in a single transaction block.

### 4. Lock-Free Stock Reservation (`reserve_stock`)
- Obtains exclusive row locks on `inventory` records via `FOR UPDATE`, checks if `quantity - reserved_quantity >= requested_quantity`, and increments `reserved_quantity` atomically.
- This optimistic locks are concurrency-safe, preventing overselling even under high user loads.
