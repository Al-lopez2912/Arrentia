import React from 'react';
import { 
  Building2, 
  Users, 
  CreditCard, 
  Settings, 
  LayoutDashboard, 
  LogOut, 
  ShieldCheck,
  Clock
} from 'lucide-react';
import { useAuth } from '../context/AuthContext';
import { getTodaySantoDomingo } from '../utils/dateUtils';

interface SidebarProps {
  currentTab: string;
  onSelectTab: (tab: string) => void;
  mobileOpen?: boolean;
  onCloseMobile?: () => void;
}

export const Sidebar: React.FC<SidebarProps> = ({
  currentTab,
  onSelectTab,
  mobileOpen = false,
  onCloseMobile,
}) => {
  const { user, signOut } = useAuth();
  const todayStr = getTodaySantoDomingo();

  const navItems = [
    { id: 'inicio', label: 'Inicio', icon: LayoutDashboard },
    { id: 'propiedades', label: 'Propiedades', icon: Building2 },
    { id: 'inquilinos', label: 'Inquilinos', icon: Users },
    { id: 'pagos', label: 'Pagos', icon: CreditCard },
    { id: 'configuracion', label: 'Configuración', icon: Settings },
  ];

  return (
    <>
      {/* Mobile Backdrop */}
      {mobileOpen && (
        <div
          className="fixed inset-0 z-40 bg-slate-900/40 backdrop-blur-xs md:hidden"
          onClick={onCloseMobile}
        />
      )}

      {/* Sidebar container */}
      <aside
        className={`fixed inset-y-0 left-0 z-50 flex w-64 flex-col border-r border-slate-200 bg-white transition-transform duration-200 ease-in-out md:static md:translate-x-0 ${
          mobileOpen ? 'translate-x-0' : '-translate-x-0 md:translate-x-0 max-md:-translate-x-full'
        }`}
      >
        {/* Brand Header */}
        <div className="flex h-16 items-center justify-between border-b border-slate-200 px-6">
          <div className="flex items-center gap-3">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-orange-600 text-white shadow-xs">
              <Building2 className="h-5 w-5" />
            </div>
            <div>
              <h1 className="text-base font-bold text-slate-900 leading-tight">Control Alquileres</h1>
              <span className="text-xs font-medium text-slate-500">República Dominicana</span>
            </div>
          </div>
        </div>

        {/* Local Time & Timezone badge */}
        <div className="border-b border-slate-100 bg-slate-50/80 px-6 py-2.5">
          <div className="flex items-center justify-between text-xs text-slate-600">
            <span className="flex items-center gap-1.5 font-medium">
              <Clock className="h-3.5 w-3.5 text-orange-600" />
              AST (Santo Domingo)
            </span>
            <span className="font-mono text-slate-500">{todayStr}</span>
          </div>
        </div>

        {/* Navigation list */}
        <nav className="flex-1 space-y-1 px-3 py-4">
          {navItems.map((item) => {
            const Icon = item.icon;
            const isActive = currentTab === item.id;
            return (
              <button
                key={item.id}
                onClick={() => {
                  onSelectTab(item.id);
                  if (onCloseMobile) onCloseMobile();
                }}
                className={`flex w-full items-center gap-3 rounded-lg px-3.5 py-2.5 text-sm font-semibold transition-colors ${
                  isActive
                    ? 'bg-orange-50 text-orange-700'
                    : 'text-slate-600 hover:bg-slate-100 hover:text-slate-900'
                }`}
              >
                <Icon
                  className={`h-4 w-4 ${
                    isActive ? 'text-orange-600' : 'text-slate-400'
                  }`}
                />
                {item.label}
              </button>
            );
          })}
        </nav>

        {/* Owner Profile & Session Footer */}
        <div className="border-t border-slate-200 p-4">
          <div className="mb-3 rounded-lg border border-slate-100 bg-slate-50 p-2.5">
            <div className="flex items-center gap-2">
              <ShieldCheck className="h-4 w-4 text-emerald-600 shrink-0" />
              <div className="min-w-0 flex-1">
                <p className="truncate text-xs font-semibold text-slate-800">
                  {user?.displayName || 'Propietario'}
                </p>
                <p className="truncate text-[11px] text-slate-500">{user?.email}</p>
              </div>
            </div>
          </div>

          <button
            onClick={() => signOut()}
            className="flex w-full items-center justify-center gap-2 rounded-lg border border-slate-200 px-3 py-2 text-xs font-medium text-slate-600 transition-colors hover:bg-slate-100 hover:text-slate-900"
          >
            <LogOut className="h-3.5 w-3.5" />
            Cerrar Sesión
          </button>
        </div>
      </aside>
    </>
  );
};
