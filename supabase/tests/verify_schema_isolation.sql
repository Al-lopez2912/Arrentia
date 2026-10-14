-- ============================================================================
-- ARRENTIA: Test Suite for Schema Integrity and RLS Isolation (V6.5)
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
  v_payment_status text;
  v_calculated_date date;
  v_gen_count integer;
  v_claim_token uuid;
  v_log_id uuid;
  v_complete_success boolean;
BEGIN
  -- Enforce explicit search path
  PERFORM set_config('search_path', 'public, auth, pg_temp', true);

  RAISE NOTICE '============================================================';
  RAISE NOTICE 'STARTING ARRENTIA SCHEMA AND SECURITY ISOLATION TEST SUITE (V6.5)';
  RAISE NOTICE '============================================================';

  -- --------------------------------------------------------------------------
  -- STEP 0: Set Up Test Fixtures Inside Uncommitted Transaction
  -- --------------------------------------------------------------------------
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

  -- Initialize settings for owner
  INSERT INTO public.settings (
    owner_id,
    notification_email,
    reminder_hour,
    timezone,
    resend_api_key_configured
  )
  VALUES (
    v_owner_id,
    v_owner_email,
    8,
    'America/Santo_Domingo',
    false
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET notification_email = EXCLUDED.notification_email;

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
    'Apartamento 101 — Gazcue',
    'Calle Moisés García #12',
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

  -- Link property to tenant
  UPDATE public.properties
  SET tenant_id = v_tenant_id
  WHERE id = v_prop_id;

  RAISE NOTICE 'TEST 1 PASSED: Property % and Tenant % successfully created by authorized owner.',
    v_prop_id, v_tenant_id;

  -- --------------------------------------------------------------------------
  -- TEST 1B: Composite Foreign Key Prevents Cross-Owner Inconsistencies
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
      v_attacker_id,
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
  -- TEST 5: Payment Financial Immutability & State Transitions
  -- --------------------------------------------------------------------------
  -- 5A: Legitimate transition to 'paid' (resolving type mismatch: status is text)
  UPDATE public.payments
  SET status = 'paid'
  WHERE id = v_payment_id;

  SELECT status INTO v_payment_status
  FROM public.payments
  WHERE id = v_payment_id;

  IF v_payment_status <> 'paid' THEN
    RAISE EXCEPTION 'TEST 5A FAILED: Payment % status was expected to be "paid", got "%"',
      v_payment_id, v_payment_status;
  END IF;

  SELECT (paid_at IS NOT NULL) INTO v_is_auth
  FROM public.payments
  WHERE id = v_payment_id;

  IF v_is_auth IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 5A FAILED: Payment % was marked paid but paid_at was NULL', v_payment_id;
  END IF;
  RAISE NOTICE 'TEST 5A PASSED: Legitimate state transition to paid accepted with auto-populated paid_at timestamp.';

  -- 5B: Reject reversion from 'paid' back to 'pending'
  BEGIN
    UPDATE public.payments
    SET status = 'pending',
        paid_at = NULL
    WHERE id = v_payment_id;

    RAISE EXCEPTION 'TEST 5B FAILED: Paid payment was reverted to pending!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5B PASSED: Reversion from paid to pending correctly rejected by trigger.';
  END;

  -- 5C: Reject modification of financial field amount_due
  BEGIN
    UPDATE public.payments
    SET amount_due = 15000
    WHERE id = v_payment_id;

    RAISE EXCEPTION 'TEST 5C FAILED: amount_due on payment was altered!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5C PASSED: Alteration of payment amount_due correctly rejected by trigger.';
  END;

  -- 5D: Reject modification of financial field due_date
  BEGIN
    UPDATE public.payments
    SET due_date = DATE '2026-04-10'
    WHERE id = v_payment_id;

    RAISE EXCEPTION 'TEST 5D FAILED: due_date on payment was altered!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5D PASSED: Alteration of payment due_date correctly rejected by trigger.';
  END;

  -- 5E: Reject modification of tenant_id once paid
  BEGIN
    UPDATE public.payments
    SET tenant_id = gen_random_uuid()
    WHERE id = v_payment_id;

    RAISE EXCEPTION 'TEST 5E FAILED: tenant_id on paid payment was altered!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5E PASSED: Alteration of tenant_id on paid payment correctly rejected by trigger.';
  END;

  -- 5F: Enforce payments_paid_status_check constraint
  -- 5F.1: Reject status = 'pending' with paid_at IS NOT NULL
  BEGIN
    INSERT INTO public.payments (
      owner_id,
      property_id,
      period,
      amount_due,
      due_date,
      status,
      paid_at
    )
    VALUES (
      v_owner_id,
      v_prop_id,
      '2026-06',
      35000,
      DATE '2026-06-05',
      'pending',
      now() -- INVALID
    );

    RAISE EXCEPTION 'TEST 5F.1 FAILED: Payment with status=pending and paid_at NOT NULL was accepted!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5F.1 PASSED: payments_paid_status_check rejected pending payment with paid_at NOT NULL.';
  END;

  -- 5F.2: Reject status = 'paid' with paid_at IS NULL
  BEGIN
    INSERT INTO public.payments (
      owner_id,
      property_id,
      period,
      amount_due,
      due_date,
      status,
      paid_at
    )
    VALUES (
      v_owner_id,
      v_prop_id,
      '2026-07',
      35000,
      DATE '2026-07-05',
      'paid',
      NULL -- INVALID
    );

    RAISE EXCEPTION 'TEST 5F.2 FAILED: Payment with status=paid and paid_at IS NULL was accepted!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 5F.2 PASSED: payments_paid_status_check rejected paid payment with paid_at IS NULL.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 6: Server-Side Due Date Calculation (Leap Years & Month Clamping)
  -- --------------------------------------------------------------------------
  -- 6A: February in Leap Year (2024-02, due_day 31 -> 2024-02-29)
  v_calculated_date := public.fn_calculate_due_date('2024-02', 31::smallint);
  IF v_calculated_date <> DATE '2024-02-29' THEN
    RAISE EXCEPTION 'TEST 6A FAILED: Expected 2024-02-29 for leap year Feb, got %', v_calculated_date;
  END IF;
  RAISE NOTICE 'TEST 6A PASSED: Leap year February correctly clamped to 2024-02-29.';

  -- 6B: February in Non-Leap Year (2026-02, due_day 31 -> 2026-02-28)
  v_calculated_date := public.fn_calculate_due_date('2026-02', 31::smallint);
  IF v_calculated_date <> DATE '2026-02-28' THEN
    RAISE EXCEPTION 'TEST 6B FAILED: Expected 2026-02-28 for non-leap Feb, got %', v_calculated_date;
  END IF;
  RAISE NOTICE 'TEST 6B PASSED: Non-leap February correctly clamped to 2026-02-28.';

  -- 6C: 30-day Month (2026-04, due_day 31 -> 2026-04-30)
  v_calculated_date := public.fn_calculate_due_date('2026-04', 31::smallint);
  IF v_calculated_date <> DATE '2026-04-30' THEN
    RAISE EXCEPTION 'TEST 6C FAILED: Expected 2026-04-30 for April, got %', v_calculated_date;
  END IF;
  RAISE NOTICE 'TEST 6C PASSED: 30-day month (April) correctly clamped to 2026-04-30.';

  -- 6D: 31-day Month (2026-03, due_day 31 -> 2026-03-31)
  v_calculated_date := public.fn_calculate_due_date('2026-03', 31::smallint);
  IF v_calculated_date <> DATE '2026-03-31' THEN
    RAISE EXCEPTION 'TEST 6D FAILED: Expected 2026-03-31 for March, got %', v_calculated_date;
  END IF;
  RAISE NOTICE 'TEST 6D PASSED: 31-day month (March) preserved as 2026-03-31.';

  -- 6E: Middle of Month (2026-05, due_day 15 -> 2026-05-15)
  v_calculated_date := public.fn_calculate_due_date('2026-05', 15::smallint);
  IF v_calculated_date <> DATE '2026-05-15' THEN
    RAISE EXCEPTION 'TEST 6E FAILED: Expected 2026-05-15, got %', v_calculated_date;
  END IF;
  RAISE NOTICE 'TEST 6E PASSED: Middle of month preserved as 2026-05-15.';

  -- --------------------------------------------------------------------------
  -- TEST 7: Idempotent Server-Side Monthly Payment Generation
  -- --------------------------------------------------------------------------
  -- 7A: Generate payments for '2026-08'
  v_gen_count := public.fn_generate_monthly_payments('2026-08', v_owner_id);
  IF v_gen_count <> 1 THEN
    RAISE EXCEPTION 'TEST 7A FAILED: Expected 1 generated payment, got %', v_gen_count;
  END IF;

  -- Verify generated payment data integrity
  SELECT amount_due, due_date, status
  INTO v_count, v_calculated_date, v_payment_status
  FROM public.payments
  WHERE id = (v_prop_id::text || '_2026-08');

  IF v_count <> 35000 OR v_calculated_date <> DATE '2026-08-05' OR v_payment_status <> 'pending' THEN
    RAISE EXCEPTION 'TEST 7A FAILED: Generated payment values inconsistent with property defaults';
  END IF;

  -- Ensure inactive property payment was NOT generated
  IF EXISTS (SELECT 1 FROM public.payments WHERE property_id = v_inactive_prop_id AND period = '2026-08') THEN
    RAISE EXCEPTION 'TEST 7A FAILED: Inactive property generated a payment!';
  END IF;
  RAISE NOTICE 'TEST 7A PASSED: fn_generate_monthly_payments generated exactly 1 valid payment for active property.';

  -- 7B: Idempotency check: running again for '2026-08' must generate 0 new payments
  v_gen_count := public.fn_generate_monthly_payments('2026-08', v_owner_id);
  IF v_gen_count <> 0 THEN
    RAISE EXCEPTION 'TEST 7B FAILED: Idempotent generation created duplicate payments (count: %)', v_gen_count;
  END IF;
  RAISE NOTICE 'TEST 7B PASSED: Re-execution of payment generation is strictly idempotent (0 duplicate rows).';

  -- --------------------------------------------------------------------------
  -- TEST 8: Reminder Worker Queue, Leasing & Fencing Token Concurrency
  -- --------------------------------------------------------------------------
  -- 8A: Worker claims job for payment due on 2026-08-05
  SELECT claim_token, log_id INTO v_claim_token, v_log_id
  FROM public.fn_claim_reminder_jobs(
    p_batch_size => 10,
    p_lease_seconds => 300,
    p_target_date => DATE '2026-08-10'
  )
  WHERE payment_id = (v_prop_id::text || '_2026-08');

  IF v_claim_token IS NULL OR v_log_id IS NULL THEN
    RAISE EXCEPTION 'TEST 8A FAILED: fn_claim_reminder_jobs failed to claim pending payment reminder!';
  END IF;
  RAISE NOTICE 'TEST 8A PASSED: Worker claimed reminder job with token % and log %', v_claim_token, v_log_id;

  -- 8B: Concurrency check: Second worker attempts to claim concurrently while lease is active
  IF EXISTS (
    SELECT 1 FROM public.fn_claim_reminder_jobs(10, 300, DATE '2026-08-10')
    WHERE payment_id = (v_prop_id::text || '_2026-08')
  ) THEN
    RAISE EXCEPTION 'TEST 8B FAILED: Active leased job was claimed by a second concurrent worker!';
  END IF;
  RAISE NOTICE 'TEST 8B PASSED: Concurrent worker claim correctly blocked by active lease.';

  -- 8C: Stale/Expired worker completion attempt with wrong or expired token fails
  v_complete_success := public.fn_complete_reminder_job(
    p_payment_id => (v_prop_id::text || '_2026-08'),
    p_claim_token => gen_random_uuid(), -- Wrong/stale token
    p_status => 'sent',
    p_provider_message_id => 'stale-msg'
  );
  IF v_complete_success IS TRUE THEN
    RAISE EXCEPTION 'TEST 8C FAILED: Expired or invalid claim token was able to complete the reminder job!';
  END IF;
  RAISE NOTICE 'TEST 8C PASSED: Stale worker update rejected by fencing token.';

  -- 8D: Legitimate worker completion with matching claim token succeeds
  v_complete_success := public.fn_complete_reminder_job(
    p_payment_id => (v_prop_id::text || '_2026-08'),
    p_claim_token => v_claim_token,
    p_status => 'sent',
    p_provider_message_id => 'resend-test-msg-123'
  );
  IF v_complete_success IS NOT TRUE THEN
    RAISE EXCEPTION 'TEST 8D FAILED: Legitimate worker failed to complete job with valid claim token!';
  END IF;

  SELECT status INTO v_payment_status
  FROM public.reminder_logs
  WHERE id = v_log_id;

  IF v_payment_status <> 'sent' THEN
    RAISE EXCEPTION 'TEST 8D FAILED: reminder_logs status expected "sent", got %', v_payment_status;
  END IF;
  RAISE NOTICE 'TEST 8D PASSED: Legitimate worker completion marked job as sent.';

  -- --------------------------------------------------------------------------
  -- TEST 9: Tenant & Property Lifecycle and ON DELETE RESTRICT Protection
  -- --------------------------------------------------------------------------
  -- 9A: Deactivating tenant safely unassigns property
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
    RAISE EXCEPTION 'TEST 9A FAILED: Deactivated tenant still has active property association!';
  END IF;
  RAISE NOTICE 'TEST 9A PASSED: Tenant deactivation safely unassigned property bindings.';

  -- 9B: Archiving property safely clears active tenant
  UPDATE public.properties
  SET active = false
  WHERE id = v_prop_id;

  SELECT tenant_id INTO v_retrieved_tenant_id
  FROM public.properties
  WHERE id = v_prop_id;

  IF v_retrieved_tenant_id IS NOT NULL THEN
    RAISE EXCEPTION 'TEST 9B FAILED: Archived property still has tenant assigned!';
  END IF;
  RAISE NOTICE 'TEST 9B PASSED: Property archiving safely cleared tenant assignment.';

  -- 9C: ON DELETE RESTRICT on properties with payment history
  BEGIN
    DELETE FROM public.properties WHERE id = v_prop_id;
    RAISE EXCEPTION 'TEST 9C FAILED: Hard deletion of property with payments was allowed!';
  EXCEPTION
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'TEST 9C PASSED: Hard delete of property with payment history correctly rejected by ON DELETE RESTRICT.';
  END;

  -- 9D: ON DELETE RESTRICT on tenants with payment history
  BEGIN
    DELETE FROM public.tenants WHERE id = v_tenant_id;
    RAISE EXCEPTION 'TEST 9D FAILED: Hard deletion of tenant with payments was allowed!';
  EXCEPTION
    WHEN foreign_key_violation THEN
      RAISE NOTICE 'TEST 9D PASSED: Hard delete of tenant with payment history correctly rejected by ON DELETE RESTRICT.';
  END;

  -- --------------------------------------------------------------------------
  -- TEST 10: RLS Isolation & Attacker Rejection
  -- --------------------------------------------------------------------------
  -- Test settings trigger: notification_email must match authorized owner
  BEGIN
    INSERT INTO public.settings (owner_id, notification_email)
    VALUES (v_owner_id, 'unauthorized_recipient@evil.com');

    RAISE EXCEPTION 'TEST 10A FAILED: Mismatched notification email on settings was accepted!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 10A PASSED: Mismatched notification email rejected by settings trigger.';
  END;

  -- Test reminder_logs trigger: recipient must match authorized owner
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
      'tenant_attacker@evil.com', -- Disallowed recipient
      DATE '2026-04-05',
      'processing'
    );

    RAISE EXCEPTION 'TEST 10B FAILED: Reminder log targeting third-party/tenant was accepted!';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'TEST 10B PASSED: Reminder log with non-owner recipient correctly rejected by trigger.';
  END;

  -- Test attacker insertion into properties with forged owner_id
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_attacker_id::text, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

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
      v_owner_id, -- Spoofing victim owner_id
      'Propiedad Suplantada',
      'Calle del Robo #1',
      50000,
      1,
      DATE '2026-01-01',
      true
    );

    RAISE EXCEPTION 'TEST 10C FAILED: Attacker was able to insert property for authorized owner!';
  EXCEPTION
    WHEN check_violation OR insufficient_privilege THEN
      RAISE NOTICE 'TEST 10C PASSED: Identity spoofing blocked by RLS / trigger.';
  END;

  -- Reset connection context
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', '', true);

  RAISE NOTICE '============================================================';
  RAISE NOTICE 'ALL ARRENTIA V6.5 INTEGRITY & SECURITY TESTS COMPLETED SUCCESSFULLY';
  RAISE NOTICE '============================================================';

END;
$$;

-- Automatic rollback: guaranteed zero residual state in production / test DB
ROLLBACK;
