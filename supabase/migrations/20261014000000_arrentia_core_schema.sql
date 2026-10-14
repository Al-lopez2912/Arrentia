-- ============================================================================
-- ARRENTIA: Core PostgreSQL / Supabase Schema Migration (Phase A - V6.3)
-- Version: 20261014000000
-- Description: Core 5-table + authorized_owners architecture with strict RLS,
--              composite foreign keys (tenant/property/owner), canonical payment IDs,
--              financial immutability triggers, reminder worker isolation, and
--              anti-probe authorization protection.
--              Native Supabase migration (uses native auth schema and roles).
-- ============================================================================

-- Ensure pgcrypto extension is available for cryptographic and UUID operations
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
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT authorized_owners_email_lowercase CHECK (email = lower(trim(email)))
);

COMMENT ON TABLE public.authorized_owners IS 'Administrative authorization registry linked to verified Supabase Auth users.';

-- ----------------------------------------------------------------------------
-- 2. Authorization Helper Function: is_authorized_owner
-- Checks whether a given user UUID is an active authorized owner.
-- Hardened against user probing: authenticated clients can only check their own UID.
-- Unauthenticated callers (anon) cannot probe any user IDs.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_authorized_owner(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_calling_uid uuid;
  v_jwt_role text;
BEGIN
  -- If no target user ID provided, evaluate as unauthorized
  IF p_user_id IS NULL THEN
    RETURN false;
  END IF;

  -- Inspect calling context
  v_calling_uid := auth.uid();
  v_jwt_role := coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    ((nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))
  );

  -- 1. Anti-probe safeguard for authenticated browser clients:
  -- If invoked by an authenticated user, they may ONLY inspect their own authorization status.
  IF (v_calling_uid IS NOT NULL OR v_jwt_role = 'authenticated') THEN
    IF v_calling_uid IS NULL OR p_user_id IS DISTINCT FROM v_calling_uid THEN
      RETURN false;
    END IF;
  END IF;

  -- 2. Anti-probe safeguard for anonymous callers:
  -- Anonymous public requests cannot inspect any user IDs.
  IF v_jwt_role = 'anon' THEN
    RETURN false;
  END IF;

  -- 3. Query the authorization registry (service_role, postgres, or verified self-check)
  RETURN EXISTS (
    SELECT 1
    FROM public.authorized_owners
    WHERE id = p_user_id
      AND is_active = true
  );
END;
$$;

COMMENT ON FUNCTION public.is_authorized_owner(uuid) IS 'Evaluates whether a user UUID is listed as an active authorized owner with anti-probing defense.';

-- ----------------------------------------------------------------------------
-- 3. Utility Function: set_updated_at
-- Trigger helper to automatically refresh updated_at timestamps.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
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
  name text NOT NULL CHECK (char_length(trim(name)) >= 1 AND char_length(name) <= 120),
  address text NOT NULL CHECK (char_length(trim(address)) >= 1 AND char_length(address) <= 255),
  monthly_rent_amount integer NOT NULL CHECK (monthly_rent_amount > 0),
  due_day smallint NOT NULL CHECK (due_day >= 1 AND due_day <= 31),
  tenant_id uuid, -- Composite FK added after tenants table creation
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
  full_name text NOT NULL CHECK (char_length(trim(full_name)) >= 2 AND char_length(full_name) <= 120),
  phone text NOT NULL CHECK (char_length(trim(phone)) >= 7 AND char_length(phone) <= 30),
  email text,
  property_id uuid,
  notes text,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tenants_id_owner_id_key UNIQUE (id, owner_id),
  CONSTRAINT fk_tenants_owner_authorized FOREIGN KEY (owner_id) REFERENCES public.authorized_owners(id) ON DELETE CASCADE,
  CONSTRAINT fk_tenants_property FOREIGN KEY (property_id, owner_id) REFERENCES public.properties(id, owner_id) ON DELETE SET NULL,
  CONSTRAINT tenants_active_property_check CHECK (active = true OR property_id IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_tenants_owner_id ON public.tenants (owner_id);
CREATE INDEX IF NOT EXISTS idx_tenants_active ON public.tenants (active);

-- Partial unique index: A property may have at most ONE active tenant at any time.
CREATE UNIQUE INDEX IF NOT EXISTS idx_tenants_active_property
ON public.tenants (property_id)
WHERE active = true AND property_id IS NOT NULL;

-- Composite foreign key from properties.tenant_id referencing tenants(id, owner_id)
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
-- Deactivating a tenant safely unassigns the property without deleting historical records.
-- Avoids unassigned OLD record access during INSERT operations.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_tenant_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- When a tenant is deactivated, clear property binding on tenant and property
    IF NEW.active = false AND OLD.active = true THEN
      NEW.property_id := NULL;

      UPDATE public.properties
      SET tenant_id = NULL,
          updated_at = now()
      WHERE (tenant_id = OLD.id OR id = OLD.property_id)
        AND owner_id = OLD.owner_id;
    ELSIF NEW.active = false AND NEW.property_id IS NOT NULL THEN
      NEW.property_id := NULL;
    END IF;
  ELSIF TG_OP = 'INSERT' THEN
    -- If inserted as inactive, property_id must remain null
    IF NEW.active = false THEN
      NEW.property_id := NULL;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenants_lifecycle ON public.tenants;
CREATE TRIGGER trg_tenants_lifecycle
BEFORE INSERT OR UPDATE ON public.tenants
FOR EACH ROW
EXECUTE FUNCTION public.trg_tenant_lifecycle();

-- ----------------------------------------------------------------------------
-- 6.1 Property Lifecycle Trigger
-- Archiving a property safely clears active tenant assignment while preserving historical records.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_property_lifecycle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.active = false AND OLD.active = true THEN
    NEW.tenant_id := NULL;

    IF OLD.tenant_id IS NOT NULL THEN
      UPDATE public.tenants
      SET property_id = NULL,
          updated_at = now()
      WHERE id = OLD.tenant_id AND owner_id = OLD.owner_id;
    END IF;
  ELSIF TG_OP = 'INSERT' AND NEW.active = false THEN
    NEW.tenant_id := NULL;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_properties_lifecycle ON public.properties;
CREATE TRIGGER trg_properties_lifecycle
BEFORE INSERT OR UPDATE OF active ON public.properties
FOR EACH ROW
EXECUTE FUNCTION public.trg_property_lifecycle();

-- ----------------------------------------------------------------------------
-- 7. Table: payments
-- Monthly payment tracking per property and period (YYYY-MM).
-- Canonical ID format: property_id::text || '_' || period.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payments (
  id text PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  property_id uuid NOT NULL,
  tenant_id uuid,
  period varchar(7) NOT NULL CHECK (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  amount_due integer NOT NULL CHECK (amount_due > 0),
  due_date date NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'paid')),
  paid_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payments_property_period_key UNIQUE (property_id, period),
  CONSTRAINT payments_canonical_id_check CHECK (id = (property_id::text || '_' || period)),
  CONSTRAINT payments_due_date_period_match CHECK (to_char(due_date, 'YYYY-MM') = period),
  CONSTRAINT fk_payments_owner_authorized FOREIGN KEY (owner_id) REFERENCES public.authorized_owners(id) ON DELETE CASCADE,
  CONSTRAINT fk_payments_property_owner FOREIGN KEY (property_id, owner_id) REFERENCES public.properties(id, owner_id) ON DELETE RESTRICT,
  CONSTRAINT fk_payments_tenant_owner FOREIGN KEY (tenant_id, owner_id) REFERENCES public.tenants(id, owner_id) ON DELETE RESTRICT,
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
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.id IS NULL OR trim(NEW.id) = '' THEN
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

-- Reject payment creation for archived/inactive properties and cross-owner inconsistencies
CREATE OR REPLACE FUNCTION public.trg_payments_reject_inactive_property()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_property_active boolean;
  v_property_owner uuid;
BEGIN
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.property_id <> OLD.property_id) THEN
    SELECT active, owner_id INTO v_property_active, v_property_owner
    FROM public.properties
    WHERE id = NEW.property_id;

    IF v_property_active IS NULL THEN
      RAISE EXCEPTION 'Property % does not exist', NEW.property_id
        USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF v_property_owner <> NEW.owner_id THEN
      RAISE EXCEPTION 'Property % does not belong to owner %', NEW.property_id, NEW.owner_id
        USING ERRCODE = 'check_violation';
    END IF;

    IF v_property_active = false THEN
      RAISE EXCEPTION 'Cannot create payment for inactive property %', NEW.property_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- Validate tenant ownership if tenant_id is specified
  IF NEW.tenant_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.tenants
      WHERE id = NEW.tenant_id AND owner_id = NEW.owner_id
    ) THEN
      RAISE EXCEPTION 'Tenant % does not belong to owner %', NEW.tenant_id, NEW.owner_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payments_check_active_property ON public.payments;
CREATE TRIGGER trg_payments_check_active_property
BEFORE INSERT OR UPDATE OF property_id, tenant_id ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.trg_payments_reject_inactive_property();

-- Payment Financial Immutability & State Transition Protection (Security Spec Payloads 7 & 8)
CREATE OR REPLACE FUNCTION public.trg_payments_enforce_immutability()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  -- 1. Structural fields cannot be mutated on update
  IF NEW.id <> OLD.id OR NEW.owner_id <> OLD.owner_id OR NEW.property_id <> OLD.property_id OR NEW.period <> OLD.period THEN
    RAISE EXCEPTION 'Cannot modify immutable payment identity fields (id, owner_id, property_id, period)'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 2. Financial fields cannot be modified once payment is generated (matches firestore.rules immutability)
  IF NEW.amount_due <> OLD.amount_due THEN
    RAISE EXCEPTION 'Payment amount_due is immutable and cannot be modified'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.due_date <> OLD.due_date THEN
    RAISE EXCEPTION 'Payment due_date is immutable and cannot be modified'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 3. State transition protection: cannot revert from 'paid' back to 'pending'
  IF OLD.status = 'paid' AND NEW.status <> 'paid' THEN
    RAISE EXCEPTION 'Illegal state transition: paid payments cannot be reverted to pending'
      USING ERRCODE = 'check_violation';
  END IF;

  -- 4. Immutability of paid payments: tenant and paid_at cannot be altered once paid
  IF OLD.status = 'paid' THEN
    IF NEW.paid_at IS DISTINCT FROM OLD.paid_at OR
       NEW.tenant_id IS DISTINCT FROM OLD.tenant_id THEN
      RAISE EXCEPTION 'Paid payments are immutable and cannot be modified'
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- 5. When marking as paid, ensure paid_at is populated
  IF OLD.status = 'pending' AND NEW.status = 'paid' THEN
    IF NEW.paid_at IS NULL THEN
      NEW.paid_at := now();
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_payments_immutability ON public.payments;
CREATE TRIGGER trg_payments_immutability
BEFORE UPDATE ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.trg_payments_enforce_immutability();

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
  IF TG_OP = 'UPDATE' AND NEW.owner_id <> OLD.owner_id THEN
    RAISE EXCEPTION 'Cannot modify owner_id on settings'
      USING ERRCODE = 'check_violation';
  END IF;

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

-- Synchronize email changes on authorized_owners to settings
CREATE OR REPLACE FUNCTION public.trg_sync_owner_email_to_settings()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.email <> OLD.email THEN
    UPDATE public.settings
    SET notification_email = NEW.email,
        updated_at = now()
    WHERE owner_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_authorized_owners_sync_settings ON public.authorized_owners;
CREATE TRIGGER trg_authorized_owners_sync_settings
AFTER UPDATE OF email ON public.authorized_owners
FOR EACH ROW
EXECUTE FUNCTION public.trg_sync_owner_email_to_settings();

-- ----------------------------------------------------------------------------
-- 9. Table: reminder_logs
-- Audit log of sent reminder emails. Written exclusively by backend/worker.
-- Reminders go strictly to the authorized owner, never to tenants.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reminder_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id uuid NOT NULL REFERENCES public.authorized_owners(id) ON DELETE CASCADE,
  payment_id text NOT NULL REFERENCES public.payments(id) ON DELETE CASCADE,
  property_id uuid NOT NULL REFERENCES public.properties(id) ON DELETE CASCADE,
  period varchar(7) NOT NULL CHECK (period ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
  recipient text NOT NULL CONSTRAINT reminder_logs_recipient_format CHECK (recipient ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
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

-- Enforce that reminder recipient is strictly the authorized owner's notification email
CREATE OR REPLACE FUNCTION public.trg_reminder_logs_enforce_owner_recipient()
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
    RAISE EXCEPTION 'Reminder logs can only be created for an active authorized owner.'
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF lower(trim(NEW.recipient)) <> lower(trim(v_owner_email)) THEN
    RAISE EXCEPTION 'Security violation: Reminders can only be dispatched to the authorized owner (%), not to tenant or third party (%)',
      v_owner_email, NEW.recipient
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reminder_logs_enforce_recipient ON public.reminder_logs;
CREATE TRIGGER trg_reminder_logs_enforce_recipient
BEFORE INSERT OR UPDATE OF owner_id, recipient ON public.reminder_logs
FOR EACH ROW
EXECUTE FUNCTION public.trg_reminder_logs_enforce_owner_recipient();

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
-- Revoke all table privileges from unauthenticated (anon) users and PUBLIC
REVOKE ALL ON TABLE public.authorized_owners FROM anon, PUBLIC;
REVOKE ALL ON TABLE public.properties FROM anon, PUBLIC;
REVOKE ALL ON TABLE public.tenants FROM anon, PUBLIC;
REVOKE ALL ON TABLE public.payments FROM anon, PUBLIC;
REVOKE ALL ON TABLE public.settings FROM anon, PUBLIC;
REVOKE ALL ON TABLE public.reminder_logs FROM anon, PUBLIC;

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
REVOKE EXECUTE ON FUNCTION public.is_authorized_owner(uuid) FROM anon, PUBLIC;

-- Internal trigger functions: revoke direct execute from anon, authenticated, and PUBLIC
-- This prevents PostgREST from exposing internal triggers as RPC callable endpoints.
REVOKE EXECUTE ON FUNCTION public.trg_set_updated_at() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trg_tenant_lifecycle() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trg_property_lifecycle() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trg_payments_enforce_canonical_id() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trg_payments_reject_inactive_property() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trg_payments_enforce_immutability() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trg_settings_enforce_owner_email() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trg_sync_owner_email_to_settings() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trg_reminder_logs_enforce_owner_recipient() FROM anon, authenticated, PUBLIC;

-- Service role maintains full access for administrative operations and background workers
GRANT ALL ON TABLE public.authorized_owners TO service_role;
GRANT ALL ON TABLE public.properties TO service_role;
GRANT ALL ON TABLE public.tenants TO service_role;
GRANT ALL ON TABLE public.payments TO service_role;
GRANT ALL ON TABLE public.settings TO service_role;
GRANT ALL ON TABLE public.reminder_logs TO service_role;
