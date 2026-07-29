-- =====================================================================
-- MULTI-TENANT INVENTORY & ORDER FULFILLMENT SYSTEM - PHASES 9-12 DDL
-- =====================================================================

-- Drop existing functions to allow recreate
DROP FUNCTION IF EXISTS public.reserve_stock(UUID, UUID, UUID, INTEGER);
DROP FUNCTION IF EXISTS public.release_stock(UUID, UUID);
DROP FUNCTION IF EXISTS public.fulfill_reservation(UUID, UUID, UUID);

-- Drop tables in order of dependencies
DROP TABLE IF EXISTS public.reconciliation_flags CASCADE;
DROP TABLE IF EXISTS public.reconciliation_reports CASCADE;
DROP TABLE IF EXISTS public.stock_reservations CASCADE;

-- 1. Stock Reservations Table
CREATE TABLE public.stock_reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE NOT NULL,
  warehouse_id UUID REFERENCES public.warehouses(id) ON DELETE CASCADE NOT NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'released', 'fulfilled')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.stock_reservations ENABLE ROW LEVEL SECURITY;

-- RLS Policies for Reservations
CREATE POLICY "Users can select reservations of their tenants" ON public.stock_reservations
  FOR SELECT USING (
    tenant_id IN (SELECT tenant_id FROM public.tenant_memberships WHERE user_id = auth.uid())
  );

CREATE POLICY "Owners, Admins, and Members can insert reservations" ON public.stock_reservations
  FOR INSERT WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );

CREATE POLICY "Owners, Admins, and Members can update reservations" ON public.stock_reservations
  FOR UPDATE USING (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );


-- 2. Reconciliation Reports Table
CREATE TABLE public.reconciliation_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE NOT NULL,
  low_stock_count INTEGER NOT NULL DEFAULT 0,
  drift_detected BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.reconciliation_reports ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can select reports of their tenants" ON public.reconciliation_reports
  FOR SELECT USING (
    tenant_id IN (SELECT tenant_id FROM public.tenant_memberships WHERE user_id = auth.uid())
  );

CREATE POLICY "System/Admins can insert reports" ON public.reconciliation_reports
  FOR INSERT WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );


-- 3. Reconciliation Flags Table
CREATE TABLE public.reconciliation_flags (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id UUID REFERENCES public.reconciliation_reports(id) ON DELETE CASCADE NOT NULL,
  tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE NOT NULL,
  warehouse_id UUID REFERENCES public.warehouses(id) ON DELETE CASCADE NOT NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('low_stock', 'drift', 'negative_sequence')),
  description TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.reconciliation_flags ENABLE ROW LEVEL SECURITY;

-- Idempotency unique constraint: only one active 'open' flag of a specific type per tenant/warehouse/product at any time
CREATE UNIQUE INDEX unique_open_flag 
  ON public.reconciliation_flags (tenant_id, warehouse_id, product_id, type) 
  WHERE (status = 'open');

CREATE POLICY "Users can select flags of their tenants" ON public.reconciliation_flags
  FOR SELECT USING (
    tenant_id IN (SELECT tenant_id FROM public.tenant_memberships WHERE user_id = auth.uid())
  );

CREATE POLICY "Owners, Admins, and Members can update/insert flags" ON public.reconciliation_flags
  FOR ALL USING (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );


-- =====================================================================
-- STORED PROCEDURES / TRANSACTION RPC CONTROLLERS
-- =====================================================================

-- RPC 1: reserve_stock
CREATE OR REPLACE FUNCTION public.reserve_stock(
  p_tenant_id UUID,
  p_warehouse_id UUID,
  p_product_id UUID,
  p_quantity INTEGER
) RETURNS UUID AS $$
DECLARE
  v_res_id UUID;
  v_current_qty INTEGER;
  v_reserved_qty INTEGER;
BEGIN
  -- Obtain inventory details and lock row for concurrent updates
  SELECT quantity, reserved_quantity INTO v_current_qty, v_reserved_qty
  FROM public.inventory
  WHERE tenant_id = p_tenant_id
    AND warehouse_id = p_warehouse_id
    AND product_id = p_product_id
  FOR UPDATE;

  -- Create default inventory record if none exists yet
  IF NOT FOUND THEN
    INSERT INTO public.inventory (tenant_id, warehouse_id, product_id, quantity, reserved_quantity)
    VALUES (p_tenant_id, p_warehouse_id, p_product_id, 0, 0);
    v_current_qty := 0;
    v_reserved_qty := 0;
  END IF;

  -- Validate sufficient unreserved stock levels
  IF v_current_qty - v_reserved_qty < p_quantity THEN
    RAISE EXCEPTION 'Insufficient unreserved stock available. Available: %, Reserved: %, Requested: %', 
      v_current_qty, v_reserved_qty, p_quantity;
  END IF;

  -- Perform atomic reservation increment
  UPDATE public.inventory
  SET reserved_quantity = reserved_quantity + p_quantity,
      updated_at = now()
  WHERE warehouse_id = p_warehouse_id
    AND product_id = p_product_id;

  -- Create reservation ledger log
  INSERT INTO public.stock_reservations (tenant_id, warehouse_id, product_id, quantity, status)
  VALUES (p_tenant_id, p_warehouse_id, p_product_id, p_quantity, 'pending')
  RETURNING id INTO v_res_id;

  RETURN v_res_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- RPC 2: release_stock
CREATE OR REPLACE FUNCTION public.release_stock(
  p_tenant_id UUID,
  p_reservation_id UUID
) RETURNS VOID AS $$
DECLARE
  v_wh_id UUID;
  v_prod_id UUID;
  v_qty INTEGER;
  v_status TEXT;
BEGIN
  -- Select and lock reservation record
  SELECT warehouse_id, product_id, quantity, status INTO v_wh_id, v_prod_id, v_qty, v_status
  FROM public.stock_reservations
  WHERE id = p_reservation_id AND tenant_id = p_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reservation record not found.';
  END IF;

  IF v_status != 'pending' THEN
    RAISE EXCEPTION 'Reservation is already in % status and cannot be released.', v_status;
  END IF;

  -- Decrement reserved quantity from inventory
  UPDATE public.inventory
  SET reserved_quantity = GREATEST(0, reserved_quantity - v_qty),
      updated_at = now()
  WHERE warehouse_id = v_wh_id
    AND product_id = v_prod_id;

  -- Update reservation status
  UPDATE public.stock_reservations
  SET status = 'released'
  WHERE id = p_reservation_id;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- RPC 3: fulfill_reservation
CREATE OR REPLACE FUNCTION public.fulfill_reservation(
  p_tenant_id UUID,
  p_reservation_id UUID,
  p_order_id UUID -- optional reference
) RETURNS VOID AS $$
DECLARE
  v_wh_id UUID;
  v_prod_id UUID;
  v_qty INTEGER;
  v_status TEXT;
  v_current_stock INTEGER;
BEGIN
  -- Select and lock reservation record
  SELECT warehouse_id, product_id, quantity, status INTO v_wh_id, v_prod_id, v_qty, v_status
  FROM public.stock_reservations
  WHERE id = p_reservation_id AND tenant_id = p_tenant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Reservation record not found.';
  END IF;

  IF v_status != 'pending' THEN
    RAISE EXCEPTION 'Reservation is in % status and cannot be fulfilled.', v_status;
  END IF;

  -- Verify inventory quantity
  SELECT quantity INTO v_current_stock
  FROM public.inventory
  WHERE warehouse_id = v_wh_id AND product_id = v_prod_id;

  IF v_current_stock < v_qty THEN
    RAISE EXCEPTION 'Cannot fulfill reservation: physical stock has dropped below reservation levels. Available: %, Reserved: %', 
      v_current_stock, v_qty;
  END IF;

  -- Decrement actual quantity and reserved quantity in inventory
  UPDATE public.inventory
  SET quantity = quantity - v_qty,
      reserved_quantity = GREATEST(0, reserved_quantity - v_qty),
      updated_at = now()
  WHERE warehouse_id = v_wh_id
    AND product_id = v_prod_id;

  -- Mark reservation fulfilled
  UPDATE public.stock_reservations
  SET status = 'fulfilled'
  WHERE id = p_reservation_id;

  -- Append to immutable stock movements log
  INSERT INTO public.stock_movements (tenant_id, warehouse_id, product_id, type, quantity, description, reference_id)
  VALUES (
    p_tenant_id, 
    v_wh_id, 
    v_prod_id, 
    'order_fulfillment', 
    -v_qty, 
    'Fulfill stock reservation: ' || p_reservation_id, 
    p_order_id
  );

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
