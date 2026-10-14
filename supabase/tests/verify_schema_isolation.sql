-- ============================================================================
-- ARRENTIA: Test Suite for Schema Integrity and RLS Isolation
-- Execution Mode: TRANSACTIONAL VALIDATION WITH AUTOMATIC ROLLBACK
-- Safe to run in psql / Supabase SQL Editor without persistent side-effects.
-- ============================================================================

BEGIN;

DO $$
DECLARE
  v_owner_id uuid;
  v_attacker_id uuid;
  v_owner_email CONSTANT text := 'mimelfis.lopez@gmail.com';
  v_prop_id uuid;
  v_inactive_prop_id uuid;
  v_tenant_id uuid;
  v_payment_id text;
  v_retrieved_prop_id uuid;
  v_retrieved_tenant_id uuid;
  v_count integer;
BEGIN
  RAISE NOTICE '============================================================';
  RAISE NOTICE 'STARTING ARRENTIA SCHEMA AND SECURITY ISOLATION TEST SUITE';
  RAISE NOTICE '============================================================';

  -- --------------------------------------------------------------------------
  -- STEP 0: Set Up Test Fixtures Inside Uncommitted Transaction
  -- --------------------------------------------------------------------------
  -- Locate or create test owner in auth.users
  SELECT id INTO v_owner_id
  FROM auth.users
  WHERE lower(email) = lower(v_owner_email);

  IF v_owner_id IS NULL THEN
    v_owner_id := gen_random_uuid();
    INSERT INTO auth.users (
      id,
      email,
      role,
      aud,
      raw_user_meta_data,
      created_at,
      updated_at
    )
    VALUES (
      v_owner_id,
      v_owner_email,
      'authenticated',
      'authenticated',
      '{"full_name": "Mimelfis López"}'::jsonb,
      now(),
      now()
    );
  END IF;

  -- Create unauthorized test attacker user in auth.users
  v_attacker_id := gen_random_uuid();
  INSERT INTO auth.users (
    id,
    email,
    role,
    aud,
    raw_user_meta_data,
    created_at,
    updated_at
  )
  VALUES (
    v_attacker_id,
    'unauthorized_test_user@example.com',
    'authenticated',
    'authenticated',
    '{"full_name": "Intruder User"}'::jsonb,
    now(),
    now()
  );

  -- Register owner in authorized_owners
  INSERT INTO public.authorized_owners (id, email, full_name, is_active)
  VALUES (v_owner_id, v_owner_email, 'Mimelfis López', true)
  ON CONFLICT (id) DO UPDATE SET is_active = true;

  -- Ensure attacker is NOT in authorized_owners
  DELETE FROM public.authorized_owners WHERE id = v_attacker_id;

  -- --------------------------------------------------------------------------
  -- TEST 1: Authorized Owner Creation of Property and Tenant
  -- --------------------------------------------------------------------------
  INSERT INTO public.properties (
    owner_id,
    name,
    address,
    monthly_rent_amount,
    due_day,
    lease_start_date,
    active
  )
  VALUES (
    v_owner_id,
    'Apartamento 3B - Bella Vista',
    'Av. Sarasota 45, Santo Domingo',
    35000,
    5,
    DATE '2026-01-01',
    true
  )
  RETURNING id INTO v_prop_id;

  INSERT INTO public.tenants (
    owner_id,
    full_name,
    phone,
    email,
    property_id,
    active
  )
  VALUES (
    v_owner_id,
    'Juan Pérez',
    '809-555-0101',
    'juan.perez@example.com',
    v_prop_id,
    true
  )
  RETURNING id INTO v_tenant_id;

  -- Link tenant to property
  UPDATE public.properties
  SET tenant_id = v_tenant_id
  WHERE id = v_prop_id;

  RAISE NOTICE 'TEST 1 PASSED: Property (%) and Tenant (%) created successfully.', v_prop_id, v_tenant_id;

  -- --------------------------------------------------------------------------
  -- TEST 2: Reject Second Active Tenant on Same Property
  -- --------------------------------------------------------------------------
  BEGIN
    INSERT INTO public.tenants (
      owner_id,
      full_name,
      phone,
      property_id,
      active
    )
    VALUES (
      v_owner_id,
      'Segundo Inquilino Concurrente',
      '809-555-0202',
      v_prop_id,
      true
    );

    RAISE EXCEPTION 'TEST 2 FAILED: Duplicate active tenant was allowed on property %', v_prop_id;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE NOTICE 'TEST 2 PASSED: Second active tenant correctly rejected by idx_tenants_active_property unique constraint.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 3: Payment Canonical ID Generation and Validation
  -- --------------------------------------------------------------------------
  -- 3A: Automatic canonical ID generation when omitted
  INSERT INTO public.payments (
    owner_id,
    property_id,
    tenant_id,
    period,
    amount_due,
    due_date,
    status
  )
  VALUES (
    v_owner_id,
    v_prop_id,
    v_tenant_id,
    '2026-04',
    35000,
    DATE '2026-04-05',
    'pending'
  )
  RETURNING id INTO v_payment_id;

  IF v_payment_id <> (v_prop_id::text || '_2026-04') THEN
    RAISE EXCEPTION 'TEST 3A FAILED: Generated payment ID (%) did not match expected canonical form (%)',
      v_payment_id, (v_prop_id::text || '_2026-04');
  END IF;
  RAISE NOTICE 'TEST 3A PASSED: Canonical payment ID generated automatically: %', v_payment_id;

  -- 3B: Reject non-canonical payment ID
  BEGIN
    INSERT INTO public.payments (
      id,
      owner_id,
      property_id,
      tenant_id,
      period,
      amount_due,
      due_date,
      status
    )
    VALUES (
      'arbitrary_invalid_id',
      v_owner_id,
      v_prop_id,
      v_tenant_id,
      '2026-05',
      35000,
      DATE '2026-05-05',
      'pending'
    );

    RAISE EXCEPTION 'TEST 3B FAILED: Invalid non-canonical payment ID was accepted!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 3B PASSED: Non-canonical payment ID correctly rejected by check_violation.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 4: Reject Payment on Inactive / Archived Property
  -- --------------------------------------------------------------------------
  INSERT INTO public.properties (
    owner_id,
    name,
    address,
    monthly_rent_amount,
    due_day,
    lease_start_date,
    active
  )
  VALUES (
    v_owner_id,
    'Propiedad Archivada de Prueba',
    'Calle Falsa 123',
    20000,
    1,
    DATE '2025-01-01',
    false -- Inactive
  )
  RETURNING id INTO v_inactive_prop_id;

  BEGIN
    INSERT INTO public.payments (
      owner_id,
      property_id,
      period,
      amount_due,
      due_date,
      status
    )
    VALUES (
      v_owner_id,
      v_inactive_prop_id,
      '2026-04',
      20000,
      DATE '2026-04-01',
      'pending'
    );

    RAISE EXCEPTION 'TEST 4 FAILED: Payment creation was allowed on inactive property %', v_inactive_prop_id;
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 4 PASSED: Payment on inactive property correctly rejected by trigger.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 5: Tenant Deactivation Lifecycle (Preserves History, Unassigns Property)
  -- --------------------------------------------------------------------------
  UPDATE public.tenants
  SET active = false
  WHERE id = v_tenant_id;

  SELECT property_id INTO v_retrieved_prop_id
  FROM public.tenants
  WHERE id = v_tenant_id;

  SELECT tenant_id INTO v_retrieved_tenant_id
  FROM public.properties
  WHERE id = v_prop_id;

  IF v_retrieved_prop_id IS NOT NULL OR v_retrieved_tenant_id IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 5 FAILED: Deactivated tenant was not unlinked from property. Tenant prop: %, Property tenant: %',
      v_retrieved_prop_id, v_retrieved_tenant_id;
  END IF;

  -- Verify historical payment record remains intact
  SELECT COUNT(*) INTO v_count
  FROM public.payments
  WHERE id = v_payment_id;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST 5 FAILED: Historical payment was unexpectedly deleted after tenant deactivation!';
  END IF;

  RAISE NOTICE 'TEST 5 PASSED: Tenant deactivated, property unassigned, historical payment preserved intact.';

  -- --------------------------------------------------------------------------
  -- TEST 6: Settings Notification Email Enforces Verified Owner Email
  -- --------------------------------------------------------------------------
  BEGIN
    INSERT INTO public.settings (
      owner_id,
      notification_email,
      reminder_hour,
      timezone
    )
    VALUES (
      v_owner_id,
      'malicious_redirect@example.com',
      8,
      'America/Santo_Domingo'
    );

    RAISE EXCEPTION 'TEST 6 FAILED: Settings accepted notification email that does not match authorized owner!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 6 PASSED: Mismatched notification email rejected by settings trigger.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 7: RLS Isolation for Unauthorized Users
  -- --------------------------------------------------------------------------
  -- Emulate non-authorized client via request.jwt.claim.sub
  PERFORM set_config('role', 'authenticated', true);
  PERFORM set_config('request.jwt.claim.sub', v_attacker_id::text, true);

  -- Attacker attempts to read properties
  SELECT COUNT(*) INTO v_count
  FROM public.properties;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 7A FAILED: Unauthorized user read % property records through RLS!', v_count;
  END IF;
  RAISE NOTICE 'TEST 7A PASSED: Unauthorized user cannot read properties (0 records returned under RLS).';

  -- Attacker attempts to insert property for themselves
  BEGIN
    INSERT INTO public.properties (
      owner_id,
      name,
      address,
      monthly_rent_amount,
      due_day,
      lease_start_date
    )
    VALUES (
      v_attacker_id,
      'Propiedad No Autorizada',
      'Calle Sin Permiso',
      15000,
      1,
      DATE '2026-06-01'
    );

    RAISE EXCEPTION 'TEST 7B FAILED: Unauthorized user was able to insert a property!';
  EXCEPTION
    WHEN insufficient_privilege OR check_violation OR integrity_constraint_violation THEN
      RAISE NOTICE 'TEST 7B PASSED: Unauthorized user insert rejected by RLS / authorization check.';
  END;

  -- Reset configuration role back to administrative session
  PERFORM set_config('role', 'postgres', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  RAISE NOTICE '============================================================';
  RAISE NOTICE 'ALL 7 INTEGRITY AND SECURITY TESTS COMPLETED SUCCESSFULLY!';
  RAISE NOTICE '============================================================';
END;
$$;

-- Always ROLLBACK so that no test data or temporary fixtures persist
ROLLBACK;
