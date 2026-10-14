import React, { createContext, useContext, useEffect, useState, useCallback } from 'react';
import { User as SupabaseUser } from '@supabase/supabase-js';
import { supabase, isSupabaseConfigured } from '../supabase';
import { UserProfile } from '../types';

export const AUTHORIZED_OWNER_EMAIL = 'mimelfis.lopez@gmail.com';

export interface AuthUser {
  id: string;
  uid: string; // Alias for backward compatibility with existing components
  email?: string;
  displayName: string;
  user_metadata?: Record<string, any>;
}

interface AuthContextType {
  user: AuthUser | null;
  userProfile: UserProfile | null;
  loading: boolean;
  isOwner: boolean;
  signInWithPassword: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
  authError: string | null;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  userProfile: null,
  loading: true,
  isOwner: false,
  signInWithPassword: async () => {},
  signOut: async () => {},
  authError: null,
});

export const AuthProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [user, setUser] = useState<AuthUser | null>(null);
  const [userProfile, setUserProfile] = useState<UserProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [authError, setAuthError] = useState<string | null>(null);

  const handleSupabaseUser = useCallback((sbUser: SupabaseUser | null) => {
    if (!sbUser) {
      setUser(null);
      setUserProfile(null);
      return;
    }

    const email = sbUser.email?.toLowerCase().trim() || '';
    const isAuthorized = email === AUTHORIZED_OWNER_EMAIL.toLowerCase().trim();

    if (!isAuthorized) {
      // Non-owner account detected: do not grant access
      setUser(null);
      setUserProfile(null);
      setAuthError(`La cuenta ${sbUser.email} no está autorizada. Este sistema es exclusivo para el propietario de Control de Alquileres.`);
      return;
    }

    const authUser: AuthUser = {
      id: sbUser.id,
      uid: sbUser.id,
      email: sbUser.email,
      displayName:
        sbUser.user_metadata?.full_name ||
        sbUser.user_metadata?.name ||
        sbUser.email?.split('@')[0] ||
        'Propietario',
      user_metadata: sbUser.user_metadata,
    };

    setUser(authUser);
    setUserProfile({
      uid: sbUser.id,
      email: sbUser.email || AUTHORIZED_OWNER_EMAIL,
      role: 'owner',
      createdAt: sbUser.created_at || new Date().toISOString(),
    });
    setAuthError(null);
  }, []);

  useEffect(() => {
    if (!isSupabaseConfigured) {
      setLoading(false);
      setAuthError('La configuración de Supabase no está disponible en las variables de entorno (VITE_SUPABASE_URL o VITE_SUPABASE_ANON_KEY).');
      return;
    }

    let isMounted = true;

    // Single source of truth for auth state (Supabase v2 emits INITIAL_SESSION on mount)
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!isMounted) return;
      handleSupabaseUser(session?.user ?? null);
      setLoading(false);
    });

    return () => {
      isMounted = false;
      subscription.unsubscribe();
    };
  }, [handleSupabaseUser]);

  const signInWithPassword = async (email: string, password: string) => {
    if (!isSupabaseConfigured) {
      setAuthError('No se puede iniciar sesión: falta la configuración de Supabase (VITE_SUPABASE_URL o VITE_SUPABASE_ANON_KEY).');
      return;
    }

    try {
      setLoading(true);
      setAuthError(null);

      const normalizedInputEmail = email.toLowerCase().trim();
      const normalizedOwnerEmail = AUTHORIZED_OWNER_EMAIL.toLowerCase().trim();

      // Guard: Ensure only the authorized owner email is submitted
      if (normalizedInputEmail !== normalizedOwnerEmail) {
        setAuthError(`La cuenta ${email} no está autorizada. Este sistema es exclusivo para el propietario de Control de Alquileres.`);
        setLoading(false);
        return;
      }

      const { data, error } = await supabase.auth.signInWithPassword({
        email: normalizedInputEmail,
        password,
      });

      if (error) {
        setAuthError(error.message || 'Credenciales inválidas.');
        setLoading(false);
        return;
      }

      if (data.user) {
        const returnedEmail = data.user.email?.toLowerCase().trim() || '';
        if (returnedEmail !== normalizedOwnerEmail) {
          // If returned user differs from authorized owner, safely sign out from the action context
          await supabase.auth.signOut();
          setUser(null);
          setUserProfile(null);
          setAuthError(`La cuenta ${data.user.email} no está autorizada.`);
          setLoading(false);
          return;
        }
        handleSupabaseUser(data.user);
      }
    } catch (err: any) {
      console.error('Error al iniciar sesión en Supabase:', err);
      setAuthError(err.message || 'Error inesperado durante la autenticación.');
    } finally {
      setLoading(false);
    }
  };

  const signOut = async () => {
    try {
      setLoading(true);
      if (isSupabaseConfigured) {
        await supabase.auth.signOut();
      }
      setUser(null);
      setUserProfile(null);
      setAuthError(null);
    } catch (err: any) {
      console.error('Error al cerrar sesión:', err);
    } finally {
      setLoading(false);
    }
  };

  const isOwner = Boolean(
    user && user.email?.toLowerCase().trim() === AUTHORIZED_OWNER_EMAIL.toLowerCase().trim()
  );

  return (
    <AuthContext.Provider
      value={{
        user,
        userProfile,
        loading,
        isOwner,
        signInWithPassword,
        signOut,
        authError,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
};

export const useAuth = () => useContext(AuthContext);
