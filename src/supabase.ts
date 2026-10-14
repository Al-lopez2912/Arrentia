import { createClient } from '@supabase/supabase-js';

/**
 * Safely retrieves environment variables across Vite browser bundles and Node.js runtimes.
 */
const getEnvVar = (key: string): string => {
  try {
    if (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env[key]) {
      return import.meta.env[key];
    }
  } catch {
    // Ignore ReferenceError if import.meta is unavailable
  }

  try {
    if (typeof process !== 'undefined' && process.env && process.env[key]) {
      return process.env[key] as string;
    }
  } catch {
    // Ignore ReferenceError if process is unavailable
  }

  return '';
};

const supabaseUrl = getEnvVar('VITE_SUPABASE_URL');
const supabaseAnonKey = getEnvVar('VITE_SUPABASE_ANON_KEY');

/**
 * Indicates whether the Supabase public credentials have been supplied via environment variables.
 */
export const isSupabaseConfigured = Boolean(
  supabaseUrl &&
  supabaseAnonKey &&
  supabaseUrl !== 'https://YOUR_PROJECT_ID.supabase.co' &&
  !supabaseUrl.includes('placeholder')
);

/**
 * Supabase client instance for client-side operations (Auth, queries).
 * Uses placeholder fallbacks if environment variables are not yet injected,
 * preventing uncaught runtime initialization errors during build time.
 */
export const supabase = createClient(
  supabaseUrl && supabaseUrl.startsWith('http') ? supabaseUrl : 'https://placeholder.supabase.co',
  supabaseAnonKey || 'placeholder-anon-key'
);
