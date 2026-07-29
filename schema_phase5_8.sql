-- =====================================================================
-- MULTI-TENANT INVENTORY & ORDER FULFILLMENT SYSTEM - PHASES 5-8 DDL
-- =====================================================================

-- Drop existing functions to allow recreate
DROP FUNCTION IF EXISTS public.adjust_stock(UUID, UUID, UUID, TEXT, INTEGER, TEXT);
DROP FUNCTION IF EXISTS public.transfer_stock(UUID, UUID, UUID, UUID, INTEGER, TEXT);
DROP FUNCTION IF EXISTS public.fulfill_order(UUID, UUID);

-- Drop tables in order of dependencies if rebuilding
DROP TABLE IF EXISTS public.order_items CASCADE;
DROP TABLE IF EXISTS public.orders CASCADE;
DROP TABLE IF EXISTS public.transfers CASCADE;
DROP TABLE IF EXISTS public.stock_movements CASCADE;
DROP TABLE IF EXISTS public.inventory CASCADE;

-- 1. Inventory Table
CREATE TABLE public.inventory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE NOT NULL,
  warehouse_id UUID REFERENCES public.warehouses(id) ON DELETE CASCADE NOT NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  quantity INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  reserved_quantity INTEGER NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, now()) NOT NULL,
  UNIQUE(warehouse_id, product_id)
);

-- Enable RLS
ALTER TABLE public.inventory ENABLE ROW LEVEL SECURITY;

-- RLS Policies for Inventory
CREATE POLICY "Users can select inventory of their tenants" ON public.inventory
  FOR SELECT USING (
    tenant_id IN (SELECT tenant_id FROM public.tenant_memberships WHERE user_id = auth.uid())
  );

CREATE POLICY "Owners, Admins, and Members can insert inventory" ON public.inventory
  FOR INSERT WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );

CREATE POLICY "Owners, Admins, and Members can update inventory" ON public.inventory
  FOR UPDATE USING (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );


-- 2. Stock Movements Table (Append-Only History)
CREATE TABLE public.stock_movements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE NOT NULL,
  warehouse_id UUID REFERENCES public.warehouses(id) ON DELETE CASCADE NOT NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('receive', 'issue', 'adjustment', 'transfer_out', 'transfer_in', 'order_fulfillment')),
  quantity INTEGER NOT NULL, -- Signed value: positive for increases, negative for decreases
  description TEXT,
  reference_id UUID, -- References transfer_id or order_id
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

-- RLS Policies for Stock Movements (Append-Only: SELECT and INSERT permitted, UPDATE and DELETE blocked)
CREATE POLICY "Users can select stock movements of their tenants" ON public.stock_movements
  FOR SELECT USING (
    tenant_id IN (SELECT tenant_id FROM public.tenant_memberships WHERE user_id = auth.uid())
  );

CREATE POLICY "Owners, Admins, and Members can insert stock movements" ON public.stock_movements
  FOR INSERT WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );


-- 3. Transfers Table (Warehouse to Warehouse logs)
CREATE TABLE public.transfers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE NOT NULL,
  source_warehouse_id UUID REFERENCES public.warehouses(id) ON DELETE CASCADE NOT NULL,
  destination_warehouse_id UUID REFERENCES public.warehouses(id) ON DELETE CASCADE NOT NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  status TEXT NOT NULL CHECK (status IN ('completed', 'failed')),
  description TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.transfers ENABLE ROW LEVEL SECURITY;

-- RLS Policies for Transfers (SELECT and INSERT allowed, no UPDATE/DELETE)
CREATE POLICY "Users can select transfers of their tenants" ON public.transfers
  FOR SELECT USING (
    tenant_id IN (SELECT tenant_id FROM public.tenant_memberships WHERE user_id = auth.uid())
  );

CREATE POLICY "Owners, Admins, and Members can insert transfers" ON public.transfers
  FOR INSERT WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );


-- 4. Orders Table
CREATE TABLE public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE NOT NULL,
  order_number TEXT NOT NULL,
  customer_name TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'fulfilled', 'cancelled')),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, now()) NOT NULL,
  UNIQUE(tenant_id, order_number)
);

-- Enable RLS
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

-- RLS Policies for Orders
CREATE POLICY "Users can select orders of their tenants" ON public.orders
  FOR SELECT USING (
    tenant_id IN (SELECT tenant_id FROM public.tenant_memberships WHERE user_id = auth.uid())
  );

CREATE POLICY "Owners, Admins, and Members can insert orders" ON public.orders
  FOR INSERT WITH CHECK (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );

CREATE POLICY "Owners, Admins, and Members can update orders" ON public.orders
  FOR UPDATE USING (
    tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships 
      WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    )
  );


-- 5. Order Items Table
CREATE TABLE public.order_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id UUID REFERENCES public.orders(id) ON DELETE CASCADE NOT NULL,
  product_id UUID REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  warehouse_id UUID REFERENCES public.warehouses(id) ON DELETE CASCADE NOT NULL,
  quantity INTEGER NOT NULL CHECK (quantity > 0),
  price NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (price >= 0)
);

-- Enable RLS
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;

-- RLS Policies for Order Items
CREATE POLICY "Users can select order items of their tenants" ON public.order_items
  FOR SELECT USING (
    order_id IN (SELECT id FROM public.orders WHERE tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships WHERE user_id = auth.uid()
    ))
  );

CREATE POLICY "Owners, Admins, and Members can insert order items" ON public.order_items
  FOR INSERT WITH CHECK (
    order_id IN (SELECT id FROM public.orders WHERE tenant_id IN (
      SELECT tenant_id FROM public.tenant_memberships WHERE user_id = auth.uid() AND role IN ('owner', 'admin', 'member')
    ))
  );


-- =====================================================================
-- STORED PROCEDURES / TRANSACTION RPC CONTROLLERS
-- =====================================================================

-- RPC 1: adjust_stock
CREATE OR REPLACE FUNCTION public.adjust_stock(
  p_tenant_id UUID,
  p_warehouse_id UUID,
  p_product_id UUID,
  p_type TEXT, -- 'receive', 'issue', 'adjustment'
  p_quantity INTEGER, -- Signed delta: positive for increases, negative for decreases
  p_description TEXT
) RETURNS VOID AS $$
DECLARE
  v_current_qty INTEGER;
BEGIN
  -- Get current stock
  SELECT quantity INTO v_current_qty
  FROM public.inventory
  WHERE tenant_id = p_tenant_id
    AND warehouse_id = p_warehouse_id
    AND product_id = p_product_id;

  IF v_current_qty IS NULL THEN
    v_current_qty := 0;
  END IF;

  -- Verify operation does not drop stock below 0
  IF v_current_qty + p_quantity < 0 THEN
    RAISE EXCEPTION 'Stock levels cannot drop below 0. Current stock: %, adjustment: %', v_current_qty, p_quantity;
  END IF;

  -- Update or Insert inventory row
  INSERT INTO public.inventory (tenant_id, warehouse_id, product_id, quantity)
  VALUES (p_tenant_id, p_warehouse_id, p_product_id, GREATEST(0, v_current_qty + p_quantity))
  ON CONFLICT (warehouse_id, product_id)
  DO UPDATE SET quantity = public.inventory.quantity + p_quantity,
                updated_at = now();

  -- Log stock movement (append-only)
  INSERT INTO public.stock_movements (tenant_id, warehouse_id, product_id, type, quantity, description)
  VALUES (p_tenant_id, p_warehouse_id, p_product_id, p_type, p_quantity, p_description);

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- RPC 2: transfer_stock
CREATE OR REPLACE FUNCTION public.transfer_stock(
  p_tenant_id UUID,
  p_source_warehouse_id UUID,
  p_destination_warehouse_id UUID,
  p_product_id UUID,
  p_quantity INTEGER,
  p_description TEXT
) RETURNS UUID AS $$
DECLARE
  v_transfer_id UUID;
  v_source_qty INTEGER;
BEGIN
  -- Validate that source and destination are different
  IF p_source_warehouse_id = p_destination_warehouse_id THEN
    RAISE EXCEPTION 'Source and destination warehouses must be different.';
  END IF;

  -- Check source warehouse stock
  SELECT quantity INTO v_source_qty
  FROM public.inventory
  WHERE tenant_id = p_tenant_id
    AND warehouse_id = p_source_warehouse_id
    AND product_id = p_product_id;

  IF v_source_qty IS NULL OR v_source_qty < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock in source warehouse. Available: %, Requested: %', COALESCE(v_source_qty, 0), p_quantity;
  END IF;

  -- Create transfer record
  INSERT INTO public.transfers (tenant_id, source_warehouse_id, destination_warehouse_id, product_id, quantity, status, description)
  VALUES (p_tenant_id, p_source_warehouse_id, p_destination_warehouse_id, p_product_id, p_quantity, 'completed', p_description)
  RETURNING id INTO v_transfer_id;

  -- Debit source warehouse
  UPDATE public.inventory
  SET quantity = quantity - p_quantity,
      updated_at = now()
  WHERE warehouse_id = p_source_warehouse_id
    AND product_id = p_product_id;

  -- Credit destination warehouse
  INSERT INTO public.inventory (tenant_id, warehouse_id, product_id, quantity)
  VALUES (p_tenant_id, p_destination_warehouse_id, p_product_id, p_quantity)
  ON CONFLICT (warehouse_id, product_id)
  DO UPDATE SET quantity = public.inventory.quantity + p_quantity,
                updated_at = now();

  -- Insert stock movements (append-only)
  INSERT INTO public.stock_movements (tenant_id, warehouse_id, product_id, type, quantity, reference_id, description)
  VALUES 
    (p_tenant_id, p_source_warehouse_id, p_product_id, 'transfer_out', -p_quantity, v_transfer_id, COALESCE(p_description, 'Cross-warehouse transfer out')),
    (p_tenant_id, p_destination_warehouse_id, p_product_id, 'transfer_in', p_quantity, v_transfer_id, COALESCE(p_description, 'Cross-warehouse transfer in'));

  RETURN v_transfer_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- RPC 3: fulfill_order
CREATE OR REPLACE FUNCTION public.fulfill_order(
  p_tenant_id UUID,
  p_order_id UUID
) RETURNS VOID AS $$
DECLARE
  v_item RECORD;
  v_current_stock INTEGER;
  v_order_num TEXT;
BEGIN
  -- Lock and verify the order is pending
  SELECT order_number INTO v_order_num 
  FROM public.orders 
  WHERE id = p_order_id AND tenant_id = p_tenant_id AND status = 'pending'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order is not in pending status or does not exist.';
  END IF;

  -- Loop through all order items and check stock
  FOR v_item IN 
    SELECT product_id, warehouse_id, quantity 
    FROM public.order_items 
    WHERE order_id = p_order_id
  LOOP
    SELECT quantity INTO v_current_stock
    FROM public.inventory
    WHERE tenant_id = p_tenant_id
      AND warehouse_id = v_item.warehouse_id
      AND product_id = v_item.product_id;

    IF v_current_stock IS NULL OR v_current_stock < v_item.quantity THEN
      RAISE EXCEPTION 'Insufficient stock in warehouse for product. Available: %, Required: %', COALESCE(v_current_stock, 0), v_item.quantity;
    END IF;
  END LOOP;

  -- Deduct stock and record movements
  FOR v_item IN 
    SELECT product_id, warehouse_id, quantity 
    FROM public.order_items 
    WHERE order_id = p_order_id
  LOOP
    -- Deduct stock
    UPDATE public.inventory
    SET quantity = quantity - v_item.quantity,
        updated_at = now()
    WHERE warehouse_id = v_item.warehouse_id
      AND product_id = v_item.product_id;

    -- Append stock movement history
    INSERT INTO public.stock_movements (tenant_id, warehouse_id, product_id, type, quantity, reference_id, description)
    VALUES (
      p_tenant_id, 
      v_item.warehouse_id, 
      v_item.product_id, 
      'order_fulfillment', 
      -v_item.quantity, 
      p_order_id, 
      'Fulfill order #' || v_order_num
    );
  END LOOP;

  -- Mark order as fulfilled
  UPDATE public.orders
  SET status = 'fulfilled'
  WHERE id = p_order_id;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
