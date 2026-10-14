-- ============================================================================
-- ARRENTIA: Core PostgreSQL / Supabase Schema Migration (Phase A)
-- Version: 20261014000000
-- Description: Core 5-table + authorized_owners architecture with strict RLS,
--              canonical payment IDs, composite foreign keys, and reminder isolation.
-- ============================================================================

-- Ensure pgcrypto extension is available for UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- 1. Table: authorized_owners
-- Controls database-level authorization. Only registered, active UUIDs
-- can access or manage Arrentia rental data.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.authorized_owners (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL UNIQUE,
  full_name text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.authorized_owners IS 'Administrative authorization registry linked to verified Supabase Auth users.';

-- ----------------------------------------------------------------------------
-- 2. Authorization Helper Function: is_authorized_owner
-- Checks whether a given user UUID is an active authorized owner.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_authorized_owner(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1
    FROM public.authorized_owners
    WHERE id = p_user_id
      AND is_active = true
  );
END;
$$;

COMMENT ON FUNCTION public.is_authorized_owner(uuid) IS 'Evaluates whether a user UUID is listed as an active authorized owner.';

-- ----------------------------------------------------------------------------
-- 3. Utility Function: set_updated_at
-- Trigger helper to automatically refresh updated_at timestamps.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. Table: properties
-- Rental properties owned by the authorized owner.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.properties (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  address text NOT NULL,
  monthly_rent_amount integer NOT NULL CHECK (monthly_rent_amount >= 0),
  due_day smallint NOT NULL CHECK (due_day >= 1 AND due_day <= 31),
  tenant_id uuid, -- FK added after tenants table creation
  lease_start_date date NOT NULL,
  lease_end_date date,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT properties_id_owner_id_key UNIQUE (id, owner_id),
  CONSTRAINT fk_properties_owner_authorized FOREIGN KEY (owner_id) REFERENCES public.authorized_owners(id) ON DELETE CASCADE,
  CONSTRAINT properties_lease_dates_check CHECK (lease_end_date IS NULL OR lease_end_date >= lease_start_date)
);

CREATE INDEX IF NOT EXISTS idx_properties_owner_id ON public.properties (owner_id);
CREATE INDEX IF NOT EXISTS idx_properties_active ON public.properties (active);

-- ----------------------------------------------------------------------------
-- 5. Table: tenants
-- Tenants associated with properties.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tenants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL,
  phone text NOT NULL,
  email text,
  property_id uuid REFERENCES public.properties(id) ON DELETE SET NULL,
  notes text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tenants_id_owner_id_key UNIQUE (id, owner_id),
  CONSTRAINT fk_tenants_owner_authorized FOREIGN KEY (owner_id) REFERENCES public.authorized_owners(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_tenants_owner_id ON public.tenants (owner_id);
CREATE INDEX IF NOT EXISTS idx_tenants_active ON public.tenants (active);

-- Partial unique index: A property may have at most ONE active tenant at any time.
CREATE UNIQUE INDEX IF NOT EXISTS idx_tenants_active_property
ON public.tenants (property_id)
WHERE active = true AND property_id IS NOT NULL;

-- Add foreign key from properties.tenant_id referencing tenants(id, owner_id)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_properties_tenant'
  ) THEN
    ALTER TABLE public.properties
    ADD CONSTRAINT fk_properties_tenant
    FOREIGN KEY (tenant_id, owner_id)
    REFERENCES public.tenants(id, owner_id)
    ON DELETE SET NULL;
  END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. Tenant Lifecycle Trigger
-- Deactivating a tenant unassigns the property without deleting historical records.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_tenant_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- When a tenant is deactivated, clear property binding on tenant
  IF NEW.active = false AND OLD.active = true THEN
    NEW.property_id := NULL;

    -- Also clear tenant_id on the assigned property
    UPDATE public.properties
    SET tenant_id = NULL,
        updated_at = now()
    WHERE tenant_id = OLD.id
      AND owner_id = OLD.owner_id;
  END IF;

  -- If inserted as inactive, ensure property_id is null
  IF TG_OP = 'INSERT' AND NEW.active = false AND NEW.property_id IS NOT NULL THEN
    NEW.property_id := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenants_lifecycle ON public.tenants;
CREATE TRIGGER trg_tenants_lifecycle
BEFORE INSERT OR UPDATE OF active ON public.tenants
FOR EACH ROW
EXECUTE FUNCTION public.trg_tenant_lifecycle();

-- ----------------------------------------------------------------------------
-- 7. Table: payments
-- Monthly payment tracking per property and period (YYYY-MM).
-- Canonical ID: property_id::text || '_' || period.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payments (
  id text PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  property_id uuid NOT NULL,
  tenant_id uuid,
  period varchar(7) NOT NULL CHECK (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  amount_due integer NOT NULL CHECK (amount_due >= 0),
  due_date date NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid')),
  paid_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payments_property_period_key UNIQUE (property_id, period),
  CONSTRAINT payments_canonical_id_check CHECK (id = (property_id::text || '_' || period)),
  CONSTRAINT fk_payments_property_owner FOREIGN KEY (property_id, owner_id) REFERENCES public.properties(id, owner_id) ON DELETE RESTRICT,
  CONSTRAINT fk_payments_tenant_owner FOREIGN KEY (tenant_id, owner_id) REFERENCES public.tenants(id, owner_id) ON DELETE SET NULL,
  CONSTRAINT payments_paid_status_check CHECK (
    (status = 'paid' AND paid_at IS NOT NULL) OR
    (status = 'pending')
  )
);

CREATE INDEX IF NOT EXISTS idx_payments_owner_id ON public.payments (owner_id);
CREATE INDEX IF NOT EXISTS idx_payments_status ON public.payments (status);
CREATE INDEX IF NOT EXISTS idx_payments_period ON public.payments (period);
CREATE INDEX IF NOT EXISTS idx_payments_due_date ON public.payments (due_date);

-- Canonical Payment ID Trigger
CREATE OR REPLACE FUNCTION public.trg_payments_enforce_canonical_id()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.id IS NULL OR NEW.id = '' THEN
    NEW.id := NEW.property_id::text || '_' || NEW.period;
  END IF;

  IF NEW.id <> (NEW.property_id::text || '_' || NEW.period) THEN
    RAISE EXCEPTION 'Invalid payment ID: expected %, received %',
      (NEW.property_id::text || '_' || NEW.period), NEW.id
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payments_canonical_id ON public.payments;
CREATE TRIGGER trg_payments_canonical_id
BEFORE INSERT OR UPDATE OF id, property_id, period ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.trg_payments_enforce_canonical_id();

-- Reject payment creation for archived/inactive properties
CREATE OR REPLACE FUNCTION public.trg_payments_reject_inactive_property()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_property_active boolean;
BEGIN
  SELECT active INTO v_property_active
  FROM public.properties
  WHERE id = NEW.property_id;

  IF v_property_active IS NULL THEN
    RAISE EXCEPTION 'Property % does not exist', NEW.property_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_property_active = false THEN
    RAISE EXCEPTION 'Cannot create payment for inactive property %', NEW.property_id
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payments_check_active_property ON public.payments;
CREATE TRIGGER trg_payments_check_active_property
BEFORE INSERT OR UPDATE OF property_id ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.trg_payments_reject_inactive_property();

-- ----------------------------------------------------------------------------
-- 8. Table: settings
-- Owner notification preferences (singleton per owner).
-- Notification email must match verified authorized owner.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL UNIQUE REFERENCES public.authorized_owners(id) ON DELETE CASCADE,
  notification_email text NOT NULL,
  reminder_hour smallint NOT NULL DEFAULT 8 CHECK (reminder_hour >= 0 AND reminder_hour <= 23),
  timezone text NOT NULL DEFAULT 'America/Santo_Domingo',
  resend_api_key_configured boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT settings_notification_email_format CHECK (notification_email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

CREATE OR REPLACE FUNCTION public.trg_settings_enforce_owner_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_owner_email text;
BEGIN
  SELECT email INTO v_owner_email
  FROM public.authorized_owners
  WHERE id = NEW.owner_id AND is_active = true;

  IF v_owner_email IS NULL THEN
    RAISE EXCEPTION 'Settings can only be established for an active authorized owner.'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF NEW.notification_email IS NULL OR trim(NEW.notification_email) = '' THEN
    NEW.notification_email := v_owner_email;
  ELSIF lower(trim(NEW.notification_email)) <> lower(trim(v_owner_email)) THEN
    RAISE EXCEPTION 'Settings notification_email (%) must match authorized owner email (%)',
      NEW.notification_email, v_owner_email
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_settings_verify_owner_email ON public.settings;
CREATE TRIGGER trg_settings_verify_owner_email
BEFORE INSERT OR UPDATE OF owner_id, notification_email ON public.settings
FOR EACH ROW
EXECUTE FUNCTION public.trg_settings_enforce_owner_email();

-- ----------------------------------------------------------------------------
-- 9. Table: reminder_logs
-- Audit log of sent reminder emails. Written exclusively by backend/worker.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reminder_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES public.authorized_owners(id) ON DELETE CASCADE,
  payment_id text NOT NULL REFERENCES public.payments(id) ON DELETE CASCADE,
  property_id uuid NOT NULL REFERENCES public.properties(id) ON DELETE CASCADE,
  period varchar(7) NOT NULL CHECK (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  recipient text NOT NULL,
  scheduled_for date NOT NULL,
  status text NOT NULL DEFAULT 'processing' CHECK (status IN ('processing', 'sent', 'failed')),
  provider_message_id text,
  attempts integer NOT NULL DEFAULT 1 CHECK (attempts >= 0),
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reminder_logs_owner_id ON public.reminder_logs (owner_id);
CREATE INDEX IF NOT EXISTS idx_reminder_logs_payment_id ON public.reminder_logs (payment_id);
CREATE INDEX IF NOT EXISTS idx_reminder_logs_status ON public.reminder_logs (status);
CREATE INDEX IF NOT EXISTS idx_reminder_logs_scheduled_for ON public.reminder_logs (scheduled_for);

-- ----------------------------------------------------------------------------
-- 10. Updated_At Triggers for All Tables
-- ----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_authorized_owners_updated_at ON public.authorized_owners;
CREATE TRIGGER trg_authorized_owners_updated_at
BEFORE UPDATE ON public.authorized_owners
FOR EACH ROW EXECUTE FUNCTION public.trg_set_updated_at();

DROP TRIGGER IF EXISTS trg_properties_updated_at ON public.properties;
CREATE TRIGGER trg_properties_updated_at
BEFORE UPDATE ON public.properties
FOR EACH ROW EXECUTE FUNCTION public.trg_set_updated_at();

DROP TRIGGER IF EXISTS trg_tenants_updated_at ON public.tenants;
CREATE TRIGGER trg_tenants_updated_at
BEFORE UPDATE ON public.tenants
FOR EACH ROW EXECUTE FUNCTION public.trg_set_updated_at();

DROP TRIGGER IF EXISTS trg_payments_updated_at ON public.payments;
CREATE TRIGGER trg_payments_updated_at
BEFORE UPDATE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.trg_set_updated_at();

DROP TRIGGER IF EXISTS trg_settings_updated_at ON public.settings;
CREATE TRIGGER trg_settings_updated_at
BEFORE UPDATE ON public.settings
FOR EACH ROW EXECUTE FUNCTION public.trg_set_updated_at();

DROP TRIGGER IF EXISTS trg_reminder_logs_updated_at ON public.reminder_logs;
CREATE TRIGGER trg_reminder_logs_updated_at
BEFORE UPDATE ON public.reminder_logs
FOR EACH ROW EXECUTE FUNCTION public.trg_set_updated_at();

-- ----------------------------------------------------------------------------
-- 11. Row Level Security (RLS) Configuration
-- ----------------------------------------------------------------------------
ALTER TABLE public.authorized_owners ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reminder_logs ENABLE ROW LEVEL SECURITY;

-- 11.1 authorized_owners policies:
-- Only authenticated user can read their own entry. No client mutations allowed.
DROP POLICY IF EXISTS "authorized_owners_select_self" ON public.authorized_owners;
CREATE POLICY "authorized_owners_select_self"
ON public.authorized_owners
FOR SELECT
TO authenticated
USING (id = auth.uid());

-- 11.2 properties policies:
-- Full tenant/property management for authorized owner; soft delete only.
DROP POLICY IF EXISTS "properties_select_authorized_owner" ON public.properties;
CREATE POLICY "properties_select_authorized_owner"
ON public.properties
FOR SELECT
TO authenticated
USING (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

DROP POLICY IF EXISTS "properties_insert_authorized_owner" ON public.properties;
CREATE POLICY "properties_insert_authorized_owner"
ON public.properties
FOR INSERT
TO authenticated
WITH CHECK (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

DROP POLICY IF EXISTS "properties_update_authorized_owner" ON public.properties;
CREATE POLICY "properties_update_authorized_owner"
ON public.properties
FOR UPDATE
TO authenticated
USING (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()))
WITH CHECK (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

-- 11.3 tenants policies:
DROP POLICY IF EXISTS "tenants_select_authorized_owner" ON public.tenants;
CREATE POLICY "tenants_select_authorized_owner"
ON public.tenants
FOR SELECT
TO authenticated
USING (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

DROP POLICY IF EXISTS "tenants_insert_authorized_owner" ON public.tenants;
CREATE POLICY "tenants_insert_authorized_owner"
ON public.tenants
FOR INSERT
TO authenticated
WITH CHECK (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

DROP POLICY IF EXISTS "tenants_update_authorized_owner" ON public.tenants;
CREATE POLICY "tenants_update_authorized_owner"
ON public.tenants
FOR UPDATE
TO authenticated
USING (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()))
WITH CHECK (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

-- 11.4 payments policies:
DROP POLICY IF EXISTS "payments_select_authorized_owner" ON public.payments;
CREATE POLICY "payments_select_authorized_owner"
ON public.payments
FOR SELECT
TO authenticated
USING (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

DROP POLICY IF EXISTS "payments_insert_authorized_owner" ON public.payments;
CREATE POLICY "payments_insert_authorized_owner"
ON public.payments
FOR INSERT
TO authenticated
WITH CHECK (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

DROP POLICY IF EXISTS "payments_update_authorized_owner" ON public.payments;
CREATE POLICY "payments_update_authorized_owner"
ON public.payments
FOR UPDATE
TO authenticated
USING (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()))
WITH CHECK (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

-- 11.5 settings policies:
DROP POLICY IF EXISTS "settings_select_authorized_owner" ON public.settings;
CREATE POLICY "settings_select_authorized_owner"
ON public.settings
FOR SELECT
TO authenticated
USING (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

DROP POLICY IF EXISTS "settings_insert_authorized_owner" ON public.settings;
CREATE POLICY "settings_insert_authorized_owner"
ON public.settings
FOR INSERT
TO authenticated
WITH CHECK (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

DROP POLICY IF EXISTS "settings_update_authorized_owner" ON public.settings;
CREATE POLICY "settings_update_authorized_owner"
ON public.settings
FOR UPDATE
TO authenticated
USING (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()))
WITH CHECK (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

-- 11.6 reminder_logs policies:
-- Authenticated owner can read logs; ONLY backend / service_role can insert/update logs.
DROP POLICY IF EXISTS "reminder_logs_select_authorized_owner" ON public.reminder_logs;
CREATE POLICY "reminder_logs_select_authorized_owner"
ON public.reminder_logs
FOR SELECT
TO authenticated
USING (owner_id = auth.uid() AND public.is_authorized_owner(auth.uid()));

-- ----------------------------------------------------------------------------
-- 12. Granular Permissions (Principle of Least Privilege)
-- ----------------------------------------------------------------------------
-- Revoke all table privileges from unauthenticated (anon) users
REVOKE ALL ON TABLE public.authorized_owners FROM anon;
REVOKE ALL ON TABLE public.properties FROM anon;
REVOKE ALL ON TABLE public.tenants FROM anon;
REVOKE ALL ON TABLE public.payments FROM anon;
REVOKE ALL ON TABLE public.settings FROM anon;
REVOKE ALL ON TABLE public.reminder_logs FROM anon;

-- Authenticated clients:
-- Can read authorized_owners to determine role
GRANT SELECT ON public.authorized_owners TO authenticated;

-- Can read and mutate core domain entities (NO DELETE: business soft delete enforced)
GRANT SELECT, INSERT, UPDATE ON public.properties TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.tenants TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.payments TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.settings TO authenticated;

-- Can only read reminder logs (worker generates them via service_role)
GRANT SELECT ON public.reminder_logs TO authenticated;

-- Helper function permissions
GRANT EXECUTE ON FUNCTION public.is_authorized_owner(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.is_authorized_owner(uuid) FROM anon, public;

-- Service role maintains full access for administrative operations and background workers
GRANT ALL ON TABLE public.authorized_owners TO service_role;
GRANT ALL ON TABLE public.properties TO service_role;
GRANT ALL ON TABLE public.tenants TO service_role;
GRANT ALL ON TABLE public.payments TO service_role;
GRANT ALL ON TABLE public.settings TO service_role;
GRANT ALL ON TABLE public.reminder_logs TO service_role;
