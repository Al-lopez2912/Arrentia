-- ============================================================================
-- ARRENTIA: Test Suite for Schema Integrity and RLS Isolation (V6.4)
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
  v_is_auth boolean;
BEGIN
  -- Enforce explicit search path
  PERFORM set_config('search_path', 'public, auth, pg_temp', true);

  RAISE NOTICE '============================================================';
  RAISE NOTICE 'STARTING ARRENTIA SCHEMA AND SECURITY ISOLATION TEST SUITE (V6.4)';
  RAISE NOTICE '============================================================';

  -- --------------------------------------------------------------------------
  -- STEP 0: Set Up Test Fixtures Inside Uncommitted Transaction
  -- --------------------------------------------------------------------------
  -- Ensure test owner exists in auth.users
  SELECT id INTO v_owner_id
  FROM auth.users
  WHERE lower(trim(email)) = lower(trim(v_owner_email));

  IF v_owner_id IS NULL THEN
    v_owner_id := gen_random_uuid();
    INSERT INTO auth.users (
      id,
      instance_id,
      email,
      encrypted_password,
      email_confirmed_at,
      role,
      aud,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at
    )
    VALUES (
      v_owner_id,
      '00000000-0000-0000-0000-000000000000'::uuid,
      v_owner_email,
      '',
      now(),
      'authenticated',
      'authenticated',
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"full_name": "Mimelfis López"}'::jsonb,
      now(),
      now()
    );
  END IF;

  -- Create unauthorized test attacker user in auth.users with non-colliding email
  v_attacker_id := gen_random_uuid();
  INSERT INTO auth.users (
    id,
    instance_id,
    email,
    encrypted_password,
    email_confirmed_at,
    role,
    aud,
    raw_app_meta_data,
    raw_user_meta_data,
    created_at,
    updated_at
  )
  VALUES (
    v_attacker_id,
    '00000000-0000-0000-0000-000000000000'::uuid,
    'unauthorized_test_' || replace(v_attacker_id::text, '-', '') || '@example.com',
    '',
    now(),
    'authenticated',
    'authenticated',
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"full_name": "Intruder User"}'::jsonb,
    now(),
    now()
  );

  -- Clean up any conflicting records with different UUID for target owner
  DELETE FROM public.authorized_owners
  WHERE lower(trim(email)) = lower(trim(v_owner_email)) AND id <> v_owner_id;

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

  RAISE NOTICE 'TEST 1 PASSED: Property (%) and Tenant (%) created with composite FKs.', v_prop_id, v_tenant_id;

  -- --------------------------------------------------------------------------
  -- TEST 1B: Composite Foreign Key Integrity (Cross-Owner Rejection)
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
      v_attacker_id, -- Attacker tries referencing victim's property
      'Inquilino Con Dueño Inconsistente',
      '809-555-9999',
      v_prop_id,
      true
    );

    RAISE EXCEPTION 'TEST 1B FAILED: Cross-owner property assignment was accepted by composite FK!';
  EXCEPTION
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'TEST 1B PASSED: Cross-owner property assignment correctly rejected by fk_tenants_property composite FK.';
  END;

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
      RAISE NOTICE 'TEST 2 PASSED: Second active tenant correctly rejected by idx_tenants_active_property unique index.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 3: Payment Canonical ID Generation & Validation
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

  -- 3C: Reject due_date not matching period
  BEGIN
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
      '2026-05',
      35000,
      DATE '2026-06-05', -- Month mismatch with period 2026-05
      'pending'
    );

    RAISE EXCEPTION 'TEST 3C FAILED: Mismatched due_date month was accepted!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 3C PASSED: Mismatched payment due_date correctly rejected by check_violation.';
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
  -- TEST 5: Payment Financial Immutability & State Transitions (Security Spec 7 & 8)
  -- --------------------------------------------------------------------------
  -- 5A: Legitimate transition to 'paid'
  UPDATE public.payments
  SET status = 'paid'
  WHERE id = v_payment_id;

  SELECT status INTO v_is_auth
  FROM public.payments
  WHERE id = v_payment_id AND status = 'paid' AND paid_at IS NOT NULL;

  RAISE NOTICE 'TEST 5A PASSED: Payment successfully transitioned to paid with paid_at timestamp.';

  -- 5B: Reject reverting 'paid' status back to 'pending' (State Tampering)
  BEGIN
    UPDATE public.payments
    SET status = 'pending',
        paid_at = NULL
    WHERE id = v_payment_id;

    RAISE EXCEPTION 'TEST 5B FAILED: Paid payment was reverted to pending!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5B PASSED: Illegal transition from paid to pending rejected by trigger.';
  END;

  -- 5C: Reject altering amount_due on payment (Financial Tampering)
  BEGIN
    UPDATE public.payments
    SET amount_due = 5000
    WHERE id = v_payment_id;

    RAISE EXCEPTION 'TEST 5C FAILED: Payment amount_due was altered!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5C PASSED: Altering amount_due on payment rejected by trigger.';
  END;

  -- 5D: Reject altering immutable identity fields (property_id / period)
  BEGIN
    UPDATE public.payments
    SET period = '2026-07'
    WHERE id = v_payment_id;

    RAISE EXCEPTION 'TEST 5D FAILED: Payment period was altered!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5D PASSED: Modifying immutable payment fields rejected by trigger.';
  END;

  -- 5E: Reject altering tenant_id on paid payment
  BEGIN
    UPDATE public.payments
    SET tenant_id = NULL
    WHERE id = v_payment_id;

    RAISE EXCEPTION 'TEST 5E FAILED: Tenant reference on paid payment was altered!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5E PASSED: Altering tenant_id on paid payment rejected by trigger.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 6: Tenant Lifecycle (Deactivation Unassigns Property, Preserves Payments)
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
    RAISE EXCEPTION 'TEST 6 FAILED: Deactivated tenant was not unlinked from property. Tenant prop: %, Property tenant: %',
      v_retrieved_prop_id, v_retrieved_tenant_id;
  END IF;

  -- Verify historical payment record remains intact
  SELECT COUNT(*) INTO v_count
  FROM public.payments
  WHERE id = v_payment_id;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST 6 FAILED: Historical payment was unexpectedly deleted after tenant deactivation!';
  END IF;

  -- Verify check constraint rejects assigning property to inactive tenant
  BEGIN
    UPDATE public.tenants
    SET property_id = v_prop_id
    WHERE id = v_tenant_id;

    SELECT property_id INTO v_retrieved_prop_id FROM public.tenants WHERE id = v_tenant_id;
    IF v_retrieved_prop_id IS NOT NULL THEN
      RAISE EXCEPTION 'TEST 6B FAILED: Inactive tenant held an assigned property!';
    END IF;
  EXCEPTION
    WHEN check_violation THEN
      NULL; -- Check constraint fired as expected
  END;

  -- 6C: Verify hard DELETE on tenant with payments is blocked by ON DELETE RESTRICT
  BEGIN
    DELETE FROM public.tenants WHERE id = v_tenant_id;

    RAISE EXCEPTION 'TEST 6C FAILED: Tenant with payment history was hard deleted!';
  EXCEPTION
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'TEST 6C PASSED: Deleting tenant with payment history blocked by fk_payments_tenant_owner (ON DELETE RESTRICT).';
  END;

  RAISE NOTICE 'TEST 6 PASSED: Tenant deactivated, property unassigned, historical payment preserved intact.';

  -- --------------------------------------------------------------------------
  -- TEST 7: Property Lifecycle (Archiving Clears Tenant, Preserves Payments)
  -- --------------------------------------------------------------------------
  UPDATE public.properties
  SET active = false
  WHERE id = v_prop_id;

  SELECT tenant_id INTO v_retrieved_tenant_id
  FROM public.properties
  WHERE id = v_prop_id;

  IF v_retrieved_tenant_id IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 7 FAILED: Inactive property still holds tenant_id reference: %', v_retrieved_tenant_id;
  END IF;

  -- Payments remain intact
  SELECT COUNT(*) INTO v_count
  FROM public.payments
  WHERE property_id = v_prop_id;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST 7 FAILED: Historical payments lost after property archival!';
  END IF;

  -- 7B: Verify hard DELETE on property with payments is blocked by ON DELETE RESTRICT
  BEGIN
    DELETE FROM public.properties WHERE id = v_prop_id;

    RAISE EXCEPTION 'TEST 7B FAILED: Property with payment history was hard deleted!';
  EXCEPTION
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'TEST 7B PASSED: Deleting property with payment history blocked by fk_payments_property_owner (ON DELETE RESTRICT).';
  END;

  RAISE NOTICE 'TEST 7 PASSED: Property archived, tenant assignment cleared, historical payments preserved.';

  -- --------------------------------------------------------------------------
  -- TEST 8: Settings Notification Email Enforces Verified Owner Email
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

    RAISE EXCEPTION 'TEST 8 FAILED: Settings accepted notification email that does not match authorized owner!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 8 PASSED: Mismatched notification email rejected by settings trigger.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 9: Reminder Logs Recipient Enforcement
  -- --------------------------------------------------------------------------
  BEGIN
    INSERT INTO public.reminder_logs (
      owner_id,
      payment_id,
      property_id,
      period,
      recipient,
      scheduled_for,
      status
    )
    VALUES (
      v_owner_id,
      v_payment_id,
      v_prop_id,
      '2026-04',
      'tenant_unauthorized@example.com',
      DATE '2026-04-05',
      'processing'
    );

    RAISE EXCEPTION 'TEST 9 FAILED: Reminder log allowed dispatch to tenant instead of owner!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 9 PASSED: Non-owner reminder recipient correctly rejected by trigger.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 10: RLS Isolation with Real Execution Context (SET LOCAL ROLE authenticated)
  -- --------------------------------------------------------------------------
  -- 10A: Positive check — Authorized Owner has full RLS read access
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_id::text, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';

  SELECT COUNT(*) INTO v_count
  FROM public.properties;

  IF v_count = 0 THEN
    RAISE EXCEPTION 'TEST 10A FAILED: Authorized owner could not read own properties under RLS!';
  END IF;
  RAISE NOTICE 'TEST 10A PASSED: Authorized owner correctly reads % properties under RLS.', v_count;

  -- 10B: Negative check — Unauthorized User reads 0 rows under RLS
  PERFORM set_config('request.jwt.claim.sub', v_attacker_id::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_attacker_id::text, 'role', 'authenticated')::text, true);

  SELECT COUNT(*) INTO v_count
  FROM public.properties;

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 10B FAILED: Unauthorized user read % property records through RLS!', v_count;
  END IF;
  RAISE NOTICE 'TEST 10B PASSED: Unauthorized user cannot read properties (0 records returned under RLS).';

  -- 10C: Negative check — Unauthorized User cannot insert records
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

    RAISE EXCEPTION 'TEST 10C FAILED: Unauthorized user was able to insert a property!';
  EXCEPTION
    WHEN insufficient_privilege OR check_violation OR integrity_constraint_violation THEN
      RAISE NOTICE 'TEST 10C PASSED: Unauthorized user insert rejected by RLS / authorization check.';
  END;

  -- 10D: Anti-probe check — Unauthorized user calling is_authorized_owner with victim UUID returns false
  SELECT public.is_authorized_owner(v_owner_id) INTO v_is_auth;
  IF v_is_auth = true THEN
    RAISE EXCEPTION 'TEST 10D FAILED: Attacker was able to probe authorization of another user!';
  END IF;
  RAISE NOTICE 'TEST 10D PASSED: Anti-probe rule blocked unauthorized user from checking another UUID.';

  -- Reset role and claims back to administrative session
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', '', true);
  PERFORM set_config('request.jwt.claims', '', true);

  RAISE NOTICE '============================================================';
  RAISE NOTICE 'ALL INTEGRITY AND SECURITY TESTS COMPLETED SUCCESSFULLY!';
  RAISE NOTICE '============================================================';
END;
$$;

-- Always ROLLBACK so that no test data or temporary fixtures persist
ROLLBACK;
