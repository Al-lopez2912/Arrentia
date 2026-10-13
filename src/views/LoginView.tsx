import React from 'react';
import { Building2, ShieldCheck, AlertCircle, LogIn, Lock } from 'lucide-react';
import { useAuth, AUTHORIZED_OWNER_EMAIL } from '../context/AuthContext';

export const LoginView: React.FC = () => {
  const { signInWithGoogle, loading, authError } = useAuth();

  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-slate-50 px-4 py-12 sm:px-6 lg:px-8">
      <div className="w-full max-w-md">
        {/* Brand Card */}
        <div className="rounded-2xl border border-slate-200 bg-white p-8 shadow-sm">
          <div className="flex flex-col items-center text-center">
            <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-orange-600 text-white shadow-md">
              <Building2 className="h-8 w-8" />
            </div>

            <h1 className="mt-5 text-2xl font-bold tracking-tight text-slate-900">
              Control de Alquileres
            </h1>
            <p className="mt-1 text-xs font-semibold uppercase tracking-wider text-orange-600">
              República Dominicana (DOP)
            </p>
            <p className="mt-2 text-sm text-slate-500 max-w-xs">
              Portal privado de gestión de propiedades, cobros y recordatorios automáticos matutinos.
            </p>
          </div>

          {/* Authorization Notice */}
          <div className="mt-6 rounded-xl border border-slate-100 bg-slate-50 p-4 text-xs text-slate-600">
            <div className="flex items-center gap-2 font-semibold text-slate-800">
              <Lock className="h-4 w-4 text-orange-600 shrink-0" />
              <span>Acceso Exclusivo para el Propietario</span>
            </div>
            <p className="mt-1 text-[11px] text-slate-500 leading-relaxed">
              Este sistema privado está protegido por autenticación Zero-Trust. No existe registro público de cuentas.
            </p>
          </div>

          {authError && (
            <div className="mt-4 flex items-start gap-2.5 rounded-xl border border-rose-200 bg-rose-50 p-3 text-xs text-rose-800">
              <AlertCircle className="h-4 w-4 text-rose-600 mt-0.5 shrink-0" />
              <div className="flex-1">
                <p className="font-semibold">Acceso Denegado</p>
                <p className="mt-0.5 text-[11px] leading-relaxed">{authError}</p>
              </div>
            </div>
          )}

          {/* Sign In Button */}
          <div className="mt-6">
            <button
              onClick={() => signInWithGoogle()}
              disabled={loading}
              className="flex w-full items-center justify-center gap-3 rounded-xl bg-slate-900 px-4 py-3 text-sm font-semibold text-white shadow-xs transition-colors hover:bg-slate-800 disabled:opacity-50"
            >
              <svg className="h-4 w-4" viewBox="0 0 24 24">
                <path
                  fill="currentColor"
                  d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
                />
                <path
                  fill="currentColor"
                  d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
                />
                <path
                  fill="currentColor"
                  d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.06H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.94l2.85-2.22.81-.63z"
                />
                <path
                  fill="currentColor"
                  d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.06l3.66 2.84c.87-2.6 3.3-4.52 6.16-4.52z"
                />
              </svg>
              <span>{loading ? 'Verificando credenciales...' : 'Iniciar Sesión con Google'}</span>
            </button>
          </div>

          <div className="mt-6 text-center text-[11px] text-slate-400">
            Zona horaria: America/Santo_Domingo (AST) • Moneda: RD$ (DOP)
          </div>
        </div>
      </div>
    </div>
  );
};
