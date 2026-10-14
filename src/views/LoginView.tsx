import React, { useState } from 'react';
import { Building2, Lock, AlertCircle, LogIn } from 'lucide-react';
import { useAuth } from '../context/AuthContext';

export const LoginView: React.FC = () => {
  const { signInWithPassword, loading, authError } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!email.trim() || !password) return;
    await signInWithPassword(email.trim(), password);
  };

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

          {/* Sign In Form */}
          <form onSubmit={handleSubmit} className="mt-6 space-y-4">
            <div>
              <label htmlFor="owner-email" className="block text-xs font-semibold text-slate-700">
                Correo Electrónico del Propietario
              </label>
              <input
                id="owner-email"
                type="email"
                autoComplete="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="propietario@ejemplo.com"
                className="mt-1.5 w-full rounded-xl border border-slate-300 px-3.5 py-2.5 text-xs text-slate-900 placeholder:text-slate-400 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
              />
            </div>

            <div>
              <label htmlFor="owner-password" className="block text-xs font-semibold text-slate-700">
                Contraseña
              </label>
              <input
                id="owner-password"
                type="password"
                autoComplete="current-password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="••••••••"
                className="mt-1.5 w-full rounded-xl border border-slate-300 px-3.5 py-2.5 text-xs text-slate-900 placeholder:text-slate-400 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
              />
            </div>

            <div className="pt-2">
              <button
                type="submit"
                disabled={loading || !email.trim() || !password}
                className="flex w-full items-center justify-center gap-2 rounded-xl bg-slate-900 px-4 py-3 text-sm font-semibold text-white shadow-xs transition-colors hover:bg-slate-800 disabled:opacity-50 cursor-pointer disabled:cursor-not-allowed"
              >
                <LogIn className="h-4 w-4" />
                <span>{loading ? 'Verificando credenciales...' : 'Iniciar Sesión'}</span>
              </button>
            </div>
          </form>

          <div className="mt-6 text-center text-[11px] text-slate-400">
            Zona horaria: America/Santo_Domingo (AST) • Moneda: RD$ (DOP)
          </div>
        </div>
      </div>
    </div>
  );
};
