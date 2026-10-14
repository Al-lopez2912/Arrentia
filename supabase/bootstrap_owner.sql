-- ============================================================================
-- ARRENTIA: Authorized Owner Bootstrap Procedure
-- Target Owner: mimelfis.lopez@gmail.com
-- Idempotent, safe, and checks real auth.users identity without synthetic UUIDs.
-- ============================================================================

DO $$
DECLARE
  v_target_email CONSTANT text := 'mimelfis.lopez@gmail.com';
  v_user_id uuid;
  v_user_email text;
  v_full_name text;
BEGIN
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
  WHERE lower(email) = lower(v_target_email);

  -- 2. Verify that the user exists in Supabase Auth
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION
      'BOOTSTRAP FAILED: User "%" was not found in auth.users. '
      'The legitimate owner must first create or confirm their account in Supabase Auth before bootstrapping database permissions. '
      'Do not insert synthetic or fabricated UUIDs.',
      v_target_email
      USING ERRCODE = 'no_data_found';
  END IF;

  -- 3. Register or activate the user in public.authorized_owners
  INSERT INTO public.authorized_owners (
    id,
    email,
    full_name,
    is_active,
    updated_at
  )
  VALUES (
    v_user_id,
    lower(v_user_email),
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

  -- 4. Idempotently initialize the default owner settings
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
    lower(v_user_email),
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
