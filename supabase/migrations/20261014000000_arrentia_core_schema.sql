-- ============================================================================
-- ARRENTIA: Core PostgreSQL / Supabase Schema Migration (Phase A - V6.5)
-- Version: 20261014000000
-- Description: Core 5-table + authorized_owners architecture with strict RLS,
--              financial integrity, idempotent server-side payment generation,
--              composite foreign keys (ON DELETE RESTRICT), and concurrency-safe
--              reminder worker queues with lease fencing.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Required Extensions
-- ----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ----------------------------------------------------------------------------
-- 2. Core Helper Functions
-- ----------------------------------------------------------------------------

-- Function: trg_set_updated_at
-- Standard trigger to maintain updated_at across all tables.
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

-- Function: is_authorized_owner
-- Validates if a user is an active authorized owner.
-- Uses SECURITY DEFINER to bypass RLS recursion on public.authorized_owners.
CREATE OR REPLACE FUNCTION public.is_authorized_owner(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.authorized_owners
    WHERE id = p_user_id
      AND is_active = true
  );
$$;

-- ----------------------------------------------------------------------------
-- 3. Table: authorized_owners
-- Single source of truth for administrative and ownership access.
-- Directly references auth.users(id).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.authorized_owners (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text NOT NULL UNIQUE CHECK (email ~* '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
  full_name text NOT NULL CHECK (char_length(trim(full_name)) >= 2 AND char_length(full_name) <= 120),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_authorized_owners_email ON public.authorized_owners (email);
CREATE INDEX IF NOT EXISTS idx_authorized_owners_active ON public.authorized_owners (is_active);

-- Security Trigger: Prevent client self-authorization in public.authorized_owners
CREATE OR REPLACE FUNCTION public.trg_protect_authorized_owners()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Disallow regular authenticated users from inserting/updating authorized_owners directly
  IF current_user IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'Unauthorized: Management of authorized_owners is restricted to administrative procedures'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_authorized_owners_protection ON public.authorized_owners;
CREATE TRIGGER trg_authorized_owners_protection
BEFORE INSERT OR UPDATE OR DELETE ON public.authorized_owners
FOR EACH ROW
EXECUTE FUNCTION public.trg_protect_authorized_owners();

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
  CONSTRAINT fk_tenants_property FOREIGN KEY (property_id, owner_id) REFERENCES public.properties(id, owner_id) ON DELETE RESTRICT,
  CONSTRAINT tenants_active_property_check CHECK (active = true OR property_id IS NULL)
);

CREATE INDEX IF NOT EXISTS idx_tenants_owner_id ON public.tenants (owner_id);
CREATE INDEX IF NOT EXISTS idx_tenants_active ON public.tenants (active);

-- Partial unique index: A property may have at most ONE active tenant at any time.
CREATE UNIQUE INDEX IF NOT EXISTS idx_tenants_active_property
ON public.tenants (property_id)
WHERE active = true AND property_id IS NOT NULL;

-- Composite foreign key from properties.tenant_id referencing tenants(id, owner_id)
-- Uses ON DELETE RESTRICT (no ON DELETE SET NULL on composite keys with NOT NULL owner_id)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_properties_tenant'
  ) THEN
    ALTER TABLE public.properties
    ADD CONSTRAINT fk_properties_tenant
    FOREIGN KEY (tenant_id, owner_id)
    REFERENCES public.tenants(id, owner_id)
    ON DELETE RESTRICT;
  END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. Tenant & Property Lifecycle Triggers
-- ----------------------------------------------------------------------------

-- 6.1 Tenant Lifecycle Trigger
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

-- 6.2 Property Lifecycle Trigger
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
-- Preserves financial history with ON DELETE RESTRICT on property and tenant.
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
    (status = 'pending' AND paid_at IS NULL)
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
-- 7.1 Server-Side Due Date Calculation & Batch Payment Generation
-- ----------------------------------------------------------------------------

-- Function: fn_calculate_due_date
-- Clamps due date to month length, correctly handling leap years, February (28/29),
-- and months with 30 or 31 days.
CREATE OR REPLACE FUNCTION public.fn_calculate_due_date(
  p_period varchar,
  p_due_day smallint
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
DECLARE
  v_month_start date;
  v_last_day_of_month integer;
  v_clamped_day integer;
BEGIN
  IF p_period IS NULL OR p_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' THEN
    RAISE EXCEPTION 'Invalid period format: expected YYYY-MM, received %', p_period
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_month_start := (p_period || '-01')::date;
  v_last_day_of_month := EXTRACT(DAY FROM (v_month_start + interval '1 month' - interval '1 day'))::integer;
  v_clamped_day := LEAST(GREATEST(COALESCE(p_due_day, 1)::integer, 1), v_last_day_of_month);

  RETURN (p_period || '-' || lpad(v_clamped_day::text, 2, '0'))::date;
END;
$$;

-- Function: fn_generate_monthly_payments
-- Server-side, idempotent, concurrency-safe monthly payment generator.
-- Excludes inactive properties.
CREATE OR REPLACE FUNCTION public.fn_generate_monthly_payments(
  p_period varchar DEFAULT NULL,
  p_owner_id uuid DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_period varchar(7);
  v_period_start date;
  v_period_end date;
  v_target_owner uuid;
  v_created_count integer := 0;
BEGIN
  -- Default period to current month in Santo Domingo timezone
  IF p_period IS NULL OR trim(p_period) = '' THEN
    v_period := to_char(now() AT TIME ZONE 'America/Santo_Domingo', 'YYYY-MM');
  ELSE
    v_period := trim(p_period);
  END IF;

  IF v_period !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' THEN
    RAISE EXCEPTION 'Invalid period format: expected YYYY-MM, received %', v_period
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_period_start := (v_period || '-01')::date;
  v_period_end := (v_period_start + interval '1 month' - interval '1 day')::date;

  -- Determine authorization scope
  IF auth.uid() IS NOT NULL THEN
    IF NOT public.is_authorized_owner(auth.uid()) THEN
      RAISE EXCEPTION 'Access denied: caller % is not an authorized owner', auth.uid()
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    v_target_owner := auth.uid();
  ELSE
    v_target_owner := p_owner_id;
  END IF;

  -- Idempotently insert payments for active properties with active leases
  WITH inserted AS (
    INSERT INTO public.payments (
      id,
      owner_id,
      property_id,
      tenant_id,
      period,
      amount_due,
      due_date,
      status,
      paid_at,
      created_at,
      updated_at
    )
    SELECT
      p.id::text || '_' || v_period AS id,
      p.owner_id,
      p.id AS property_id,
      p.tenant_id,
      v_period AS period,
      p.monthly_rent_amount AS amount_due,
      public.fn_calculate_due_date(v_period, p.due_day) AS due_date,
      'pending' AS status,
      NULL::timestamptz AS paid_at,
      now() AS created_at,
      now() AS updated_at
    FROM public.properties p
    JOIN public.authorized_owners ao ON ao.id = p.owner_id
    WHERE p.active = true
      AND ao.is_active = true
      AND (v_target_owner IS NULL OR p.owner_id = v_target_owner)
      AND p.lease_start_date <= v_period_end
      AND (p.lease_end_date IS NULL OR p.lease_end_date >= v_period_start)
    ON CONFLICT (property_id, period) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_created_count FROM inserted;

  RETURN v_created_count;
END;
$$;

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
-- Audit log of sent reminder emails with concurrency control & leasing.
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
  claim_token uuid,
  lease_expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reminder_logs_payment_key UNIQUE (payment_id)
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
-- 9.1 Helper Functions for Reminder Worker (Concurrency & Distributed Queue)
-- ----------------------------------------------------------------------------

-- Function: fn_claim_reminder_jobs
-- Atomically claims reminder jobs for pending payments due on/before target date.
-- Uses FOR UPDATE OF p SKIP LOCKED and leasing to prevent race conditions.
CREATE OR REPLACE FUNCTION public.fn_claim_reminder_jobs(
  p_batch_size integer DEFAULT 10,
  p_lease_seconds integer DEFAULT 300,
  p_target_date date DEFAULT NULL
)
RETURNS TABLE (
  log_id uuid,
  payment_id text,
  property_id uuid,
  property_name text,
  tenant_name text,
  owner_id uuid,
  recipient text,
  period varchar,
  amount_due integer,
  due_date date,
  attempts integer,
  claim_token uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_today date;
  v_lease_duration interval;
BEGIN
  v_today := COALESCE(p_target_date, (now() AT TIME ZONE 'America/Santo_Domingo')::date);
  v_lease_duration := (COALESCE(p_lease_seconds, 300) || ' seconds')::interval;

  RETURN QUERY
  WITH candidate_payments AS (
    SELECT
      p.id AS c_payment_id,
      p.property_id AS c_property_id,
      prop.name AS c_property_name,
      t.full_name AS c_tenant_name,
      p.owner_id AS c_owner_id,
      s.notification_email AS c_recipient,
      p.period AS c_period,
      p.amount_due AS c_amount_due,
      p.due_date AS c_due_date,
      rl.id AS c_existing_log_id,
      COALESCE(rl.attempts, 0) + 1 AS c_next_attempts,
      gen_random_uuid() AS c_token
    FROM public.payments p
    JOIN public.properties prop ON prop.id = p.property_id
    JOIN public.authorized_owners ao ON ao.id = p.owner_id
    JOIN public.settings s ON s.owner_id = p.owner_id
    LEFT JOIN public.tenants t ON t.id = p.tenant_id
    LEFT JOIN public.reminder_logs rl ON rl.payment_id = p.id
    WHERE p.status = 'pending'
      AND p.due_date <= v_today
      AND prop.active = true
      AND ao.is_active = true
      AND (
        rl.id IS NULL
        OR (
          rl.status <> 'sent'
          AND (rl.status = 'failed' OR rl.lease_expires_at < now())
        )
      )
    ORDER BY p.due_date ASC, p.created_at ASC
    LIMIT p_batch_size
    FOR UPDATE OF p SKIP LOCKED
  ),
  upserted_logs AS (
    INSERT INTO public.reminder_logs (
      id,
      owner_id,
      payment_id,
      property_id,
      period,
      recipient,
      scheduled_for,
      status,
      attempts,
      claim_token,
      lease_expires_at,
      created_at,
      updated_at
    )
    SELECT
      COALESCE(cp.c_existing_log_id, gen_random_uuid()),
      cp.c_owner_id,
      cp.c_payment_id,
      cp.c_property_id,
      cp.c_period,
      cp.c_recipient,
      cp.c_due_date,
      'processing',
      cp.c_next_attempts,
      cp.c_token,
      now() + v_lease_duration,
      now(),
      now()
    FROM candidate_payments cp
    ON CONFLICT (payment_id) DO UPDATE
    SET
      status = 'processing',
      attempts = EXCLUDED.attempts,
      claim_token = EXCLUDED.claim_token,
      lease_expires_at = EXCLUDED.lease_expires_at,
      recipient = EXCLUDED.recipient,
      scheduled_for = EXCLUDED.scheduled_for,
      updated_at = now()
    WHERE public.reminder_logs.status <> 'sent'
      AND (public.reminder_logs.status = 'failed' OR public.reminder_logs.lease_expires_at < now())
    RETURNING
      id,
      payment_id,
      property_id,
      owner_id,
      recipient,
      period,
      attempts,
      claim_token
  )
  SELECT
    ul.id AS log_id,
    ul.payment_id,
    ul.property_id,
    cp.c_property_name AS property_name,
    cp.c_tenant_name AS tenant_name,
    ul.owner_id,
    ul.recipient,
    ul.period,
    cp.c_amount_due AS amount_due,
    cp.c_due_date AS due_date,
    ul.attempts,
    ul.claim_token
  FROM upserted_logs ul
  JOIN candidate_payments cp ON cp.c_payment_id = ul.payment_id;
END;
$$;

-- Function: fn_complete_reminder_job
-- Idempotently marks a reminder job as sent or failed.
-- Protected by claim_token to prevent expired workers from overwriting fresher state.
CREATE OR REPLACE FUNCTION public.fn_complete_reminder_job(
  p_payment_id text,
  p_claim_token uuid,
  p_status text,
  p_provider_message_id text DEFAULT NULL,
  p_error text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_updated_count integer;
BEGIN
  IF p_status NOT IN ('sent', 'failed') THEN
    RAISE EXCEPTION 'Invalid completion status: %, expected "sent" or "failed"', p_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  UPDATE public.reminder_logs
  SET
    status = p_status,
    provider_message_id = CASE WHEN p_status = 'sent' THEN COALESCE(p_provider_message_id, 'ok') ELSE NULL END,
    last_error = CASE WHEN p_status = 'failed' THEN p_error ELSE NULL END,
    claim_token = NULL,
    lease_expires_at = NULL,
    updated_at = now()
  WHERE payment_id = p_payment_id
    AND claim_token = p_claim_token
    AND (lease_expires_at >= now() OR status = 'processing');

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;

  RETURN (v_updated_count > 0);
END;
$$;

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

-- Helper and RPC function permissions
GRANT EXECUTE ON FUNCTION public.is_authorized_owner(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.is_authorized_owner(uuid) FROM anon, PUBLIC;

GRANT EXECUTE ON FUNCTION public.fn_calculate_due_date(varchar, smallint) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_calculate_due_date(varchar, smallint) FROM anon, PUBLIC;

GRANT EXECUTE ON FUNCTION public.fn_generate_monthly_payments(varchar, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.fn_generate_monthly_payments(varchar, uuid) FROM anon, PUBLIC;

GRANT EXECUTE ON FUNCTION public.fn_claim_reminder_jobs(integer, integer, date) TO service_role;
REVOKE EXECUTE ON FUNCTION public.fn_claim_reminder_jobs(integer, integer, date) FROM anon, authenticated, PUBLIC;

GRANT EXECUTE ON FUNCTION public.fn_complete_reminder_job(text, uuid, text, text, text) TO service_role;
REVOKE EXECUTE ON FUNCTION public.fn_complete_reminder_job(text, uuid, text, text, text) FROM anon, authenticated, PUBLIC;

-- Internal trigger functions: revoke direct execute from anon, authenticated, and PUBLIC
-- This prevents PostgREST from exposing internal triggers as RPC callable endpoints.
REVOKE EXECUTE ON FUNCTION public.trg_set_updated_at() FROM anon, authenticated, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.trg_protect_authorized_owners() FROM anon, authenticated, PUBLIC;
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
