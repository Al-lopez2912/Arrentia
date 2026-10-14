-- ============================================================================
-- ARRENTIA: Authorized Owner Bootstrap Procedure (V6.3)
-- Target Owner: mimelfis.lopez@gmail.com
-- Idempotent, safe, and checks real auth.users identity without synthetic UUIDs.
-- ============================================================================

DO $$
DECLARE
  v_target_email CONSTANT text := 'mimelfis.lopez@gmail.com';
  v_test_account_email CONSTANT text := 'erickfeliz2026startup@gmail.com';
  v_user_id uuid;
  v_user_email text;
  v_full_name text;
BEGIN
  -- Set explicit search path for execution security
  PERFORM set_config('search_path', 'public, auth, pg_temp', true);

  -- 1. Query the actual verified UUID from auth.users
  SELECT
    id,
    email,
    COALESCE(
      raw_user_meta_data->>'full_name',
      raw_user_meta_data->>'name',
      'Mimelfis López'
    )
  INTO v_user_id, v_user_email, v_full_name
  FROM auth.users
  WHERE lower(trim(email)) = lower(trim(v_target_email));

  -- 2. Verify that the user exists in Supabase Auth
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION
      'BOOTSTRAP FAILED: User "%" was not found in auth.users. '
      'The legitimate owner must first create or confirm their account in Supabase Auth before bootstrapping database permissions. '
      'Do not insert synthetic or fabricated UUIDs.',
      v_target_email
      USING ERRCODE = 'no_data_found';
  END IF;

  -- 3. Revoke/deactivate temporary test accounts to ensure single-owner invariant
  UPDATE public.authorized_owners
  SET is_active = false,
      updated_at = now()
  WHERE lower(trim(email)) = lower(trim(v_test_account_email))
     OR (lower(trim(email)) <> lower(trim(v_target_email)) AND is_active = true);

  -- 4. If an obsolete record exists with the target email but different UUID, migrate data safely
  IF EXISTS (
    SELECT 1 FROM public.authorized_owners
    WHERE lower(trim(email)) = lower(trim(v_target_email)) AND id <> v_user_id
  ) THEN
    UPDATE public.properties SET owner_id = v_user_id WHERE owner_id IN (
      SELECT id FROM public.authorized_owners WHERE lower(trim(email)) = lower(trim(v_target_email)) AND id <> v_user_id
    );
    UPDATE public.tenants SET owner_id = v_user_id WHERE owner_id IN (
      SELECT id FROM public.authorized_owners WHERE lower(trim(email)) = lower(trim(v_target_email)) AND id <> v_user_id
    );
    UPDATE public.payments SET owner_id = v_user_id WHERE owner_id IN (
      SELECT id FROM public.authorized_owners WHERE lower(trim(email)) = lower(trim(v_target_email)) AND id <> v_user_id
    );
    UPDATE public.settings SET owner_id = v_user_id WHERE owner_id IN (
      SELECT id FROM public.authorized_owners WHERE lower(trim(email)) = lower(trim(v_target_email)) AND id <> v_user_id
    );
    DELETE FROM public.authorized_owners
    WHERE lower(trim(email)) = lower(trim(v_target_email)) AND id <> v_user_id;
  END IF;

  -- 5. Register or activate the legitimate owner in public.authorized_owners
  INSERT INTO public.authorized_owners (
    id,
    email,
    full_name,
    is_active,
    updated_at
  )
  VALUES (
    v_user_id,
    lower(trim(v_user_email)),
    v_full_name,
    true,
    now()
  )
  ON CONFLICT (id) DO UPDATE
  SET
    email = EXCLUDED.email,
    full_name = EXCLUDED.full_name,
    is_active = true,
    updated_at = now();

  -- 6. Idempotently initialize the default owner settings
  INSERT INTO public.settings (
    owner_id,
    notification_email,
    reminder_hour,
    timezone,
    resend_api_key_configured,
    updated_at
  )
  VALUES (
    v_user_id,
    lower(trim(v_user_email)),
    8,
    'America/Santo_Domingo',
    false,
    now()
  )
  ON CONFLICT (owner_id) DO UPDATE
  SET
    notification_email = EXCLUDED.notification_email,
    updated_at = now();

  RAISE NOTICE 'SUCCESS: Authorized owner "%" (UUID: %) registered and configured successfully.',
    v_target_email, v_user_id;
END;
$$;
