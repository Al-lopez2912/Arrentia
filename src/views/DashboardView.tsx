import React from 'react';
import { 
  Building2, 
  CreditCard, 
  AlertCircle, 
  CheckCircle2, 
  CalendarClock, 
  ArrowUpRight, 
  PlusCircle, 
  RefreshCw,
  Clock
} from 'lucide-react';
import { Property, Tenant, Payment } from '../types';
import { 
  formatCurrencyDOP, 
  formatPeriodSpanish, 
  formatDateSpanish, 
  isPaymentOverdue, 
  isPaymentDueToday,
  getCurrentPeriodSantoDomingo,
  getTodaySantoDomingo
} from '../utils/dateUtils';

interface DashboardViewProps {
  properties: Property[];
  tenants: Tenant[];
  payments: Payment[];
  onNavigate: (tab: string) => void;
  onRefresh: () => void;
  onEnsurePayments: () => void;
  isGenerating?: boolean;
}

export const DashboardView: React.FC<DashboardViewProps> = ({
  properties,
  tenants,
  payments,
  onNavigate,
  onRefresh,
  onEnsurePayments,
  isGenerating = false,
}) => {
  const currentPeriod = getCurrentPeriodSantoDomingo();
  const todayStr = getTodaySantoDomingo();

  // Metric 1: Total active properties
  const activeProperties = properties.filter((p) => p.active);

  // Metric 2: Expected monthly rent for active properties
  const expectedMonthlyRent = activeProperties.reduce((sum, p) => sum + (p.monthlyRentAmount || 0), 0);

  // Payments for current period
  const currentMonthPayments = payments.filter((p) => p.period === currentPeriod);

  // Metric 3: Amount collected this month
  const collectedThisMonth = currentMonthPayments
    .filter((p) => p.status === 'paid')
    .reduce((sum, p) => sum + p.amountDue, 0);

  // Metric 4: Amount pending this month
  const pendingThisMonth = currentMonthPayments
    .filter((p) => p.status === 'pending')
    .reduce((sum, p) => sum + p.amountDue, 0);

  // Metric 5: Number of overdue payments (all pending payments whose dueDate < today)
  const overduePayments = payments.filter((p) => isPaymentOverdue(p.dueDate, p.status, todayStr));

  // Metric 6: Payments due today
  const paymentsDueToday = payments.filter((p) => isPaymentDueToday(p.dueDate, p.status, todayStr));

  // Mapping helpers for display
  const propertyMap = new Map(properties.map((p) => [p.id, p]));
  const tenantMap = new Map(tenants.map((t) => [t.id, t]));

  return (
    <div className="space-y-6">
      {/* Top Welcome & Actions Banner */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-xl font-bold text-slate-900 tracking-tight sm:text-2xl">
            Resumen General
          </h2>
          <p className="text-sm text-slate-500 mt-1">
            Período actual: <span className="font-semibold text-slate-700">{formatPeriodSpanish(currentPeriod)}</span> • Zona: America/Santo_Domingo
          </p>
        </div>

        <div className="flex items-center gap-2">
          <button
            onClick={onRefresh}
            className="flex items-center gap-2 rounded-lg border border-slate-200 bg-white px-3.5 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50 transition-colors shadow-2xs"
            title="Recargar datos de Firestore"
          >
            <RefreshCw className="h-3.5 w-3.5 text-slate-500" />
            Actualizar
          </button>
          <button
            onClick={onEnsurePayments}
            disabled={isGenerating || activeProperties.length === 0}
            className="flex items-center gap-2 rounded-lg bg-orange-600 px-3.5 py-2 text-xs font-semibold text-white hover:bg-orange-700 transition-colors shadow-2xs disabled:opacity-50"
          >
            <CalendarClock className="h-3.5 w-3.5" />
            {isGenerating ? 'Generando...' : 'Generar Pagos del Mes'}
          </button>
        </div>
      </div>

      {/* Critical Alert Banners */}
      {paymentsDueToday.length > 0 && (
        <div className="flex items-start gap-3 rounded-xl border border-orange-200 bg-orange-50/70 p-4 text-orange-950">
          <Clock className="h-5 w-5 text-orange-600 mt-0.5 shrink-0" />
          <div className="flex-1">
            <h4 className="text-sm font-bold">
              {paymentsDueToday.length} {paymentsDueToday.length === 1 ? 'pago vence hoy' : 'pagos vencen hoy'} ({formatDateSpanish(todayStr)})
            </h4>
            <p className="text-xs text-orange-800 mt-0.5">
              El sistema ha programado el envío del recordatorio matutino para estas obligaciones pendientes.
            </p>
          </div>
          <button
            onClick={() => onNavigate('pagos')}
            className="shrink-0 rounded-lg bg-orange-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-orange-700"
          >
            Ver Pagos
          </button>
        </div>
      )}

      {overduePayments.length > 0 && (
        <div className="flex items-start gap-3 rounded-xl border border-rose-200 bg-rose-50/70 p-4 text-rose-950">
          <AlertCircle className="h-5 w-5 text-rose-600 mt-0.5 shrink-0" />
          <div className="flex-1">
            <h4 className="text-sm font-bold">
              {overduePayments.length} {overduePayments.length === 1 ? 'alquiler vencido' : 'alquileres vencidos'}
            </h4>
            <p className="text-xs text-rose-800 mt-0.5">
              Existen pagos pendientes cuya fecha de vencimiento ya expiró.
            </p>
          </div>
          <button
            onClick={() => onNavigate('pagos')}
            className="shrink-0 rounded-lg bg-rose-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-rose-700"
          >
            Revisar
          </button>
        </div>
      )}

      {/* 6 Key Metrics Cards */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {/* Metric 1 */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-500">
              Propiedades Activas
            </span>
            <div className="rounded-lg bg-slate-100 p-2 text-slate-600">
              <Building2 className="h-4 w-4" />
            </div>
          </div>
          <p className="mt-3 text-2xl font-bold text-slate-900 font-mono">
            {activeProperties.length}
          </p>
          <p className="mt-1 text-xs text-slate-500">
            {properties.length - activeProperties.length} archivadas
          </p>
        </div>

        {/* Metric 2 */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-500">
              Renta Mensual Esperada
            </span>
            <div className="rounded-lg bg-orange-100 p-2 text-orange-600">
              <CreditCard className="h-4 w-4" />
            </div>
          </div>
          <p className="mt-3 text-2xl font-bold text-slate-900 font-mono">
            {formatCurrencyDOP(expectedMonthlyRent)}
          </p>
          <p className="mt-1 text-xs text-slate-500">
            Total contratado para {formatPeriodSpanish(currentPeriod)}
          </p>
        </div>

        {/* Metric 3 */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-500">
              Cobrado Este Mes
            </span>
            <div className="rounded-lg bg-emerald-100 p-2 text-emerald-600">
              <CheckCircle2 className="h-4 w-4" />
            </div>
          </div>
          <p className="mt-3 text-2xl font-bold text-emerald-700 font-mono">
            {formatCurrencyDOP(collectedThisMonth)}
          </p>
          <p className="mt-1 text-xs text-slate-500">
            {currentMonthPayments.filter((p) => p.status === 'paid').length} de {currentMonthPayments.length} obligaciones
          </p>
        </div>

        {/* Metric 4 */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-500">
              Pendiente Este Mes
            </span>
            <div className="rounded-lg bg-amber-100 p-2 text-amber-600">
              <Clock className="h-4 w-4" />
            </div>
          </div>
          <p className="mt-3 text-2xl font-bold text-slate-900 font-mono">
            {formatCurrencyDOP(pendingThisMonth)}
          </p>
          <p className="mt-1 text-xs text-slate-500">
            Por cobrar en {formatPeriodSpanish(currentPeriod)}
          </p>
        </div>

        {/* Metric 5 */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-500">
              Pagos Vencidos
            </span>
            <div className="rounded-lg bg-rose-100 p-2 text-rose-600">
              <AlertCircle className="h-4 w-4" />
            </div>
          </div>
          <p className={`mt-3 text-2xl font-bold font-mono ${overduePayments.length > 0 ? 'text-rose-600' : 'text-slate-900'}`}>
            {overduePayments.length}
          </p>
          <p className="mt-1 text-xs text-slate-500">
            Fecha de pago expirada
          </p>
        </div>

        {/* Metric 6 */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center justify-between">
            <span className="text-xs font-semibold uppercase tracking-wider text-slate-500">
              Vencen Hoy
            </span>
            <div className="rounded-lg bg-orange-100 p-2 text-orange-600">
              <CalendarClock className="h-4 w-4" />
            </div>
          </div>
          <p className="mt-3 text-2xl font-bold text-orange-700 font-mono">
            {paymentsDueToday.length}
          </p>
          <p className="mt-1 text-xs text-slate-500">
            {formatDateSpanish(todayStr)}
          </p>
        </div>
      </div>

      {/* Snapshot Section */}
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        {/* Properties Snapshot */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center justify-between border-b border-slate-100 pb-4">
            <h3 className="text-sm font-bold text-slate-900">Propiedades Activas</h3>
            <button
              onClick={() => onNavigate('propiedades')}
              className="flex items-center gap-1 text-xs font-semibold text-orange-600 hover:text-orange-700"
            >
              Ver todas <ArrowUpRight className="h-3.5 w-3.5" />
            </button>
          </div>

          <div className="mt-4 divide-y divide-slate-100">
            {activeProperties.length === 0 ? (
              <div className="py-8 text-center">
                <Building2 className="mx-auto h-8 w-8 text-slate-300" />
                <p className="mt-2 text-xs font-medium text-slate-500">
                  No hay propiedades registradas aún.
                </p>
                <button
                  onClick={() => onNavigate('propiedades')}
                  className="mt-3 inline-flex items-center gap-1.5 rounded-lg bg-orange-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-orange-700"
                >
                  <PlusCircle className="h-3.5 w-3.5" />
                  Registrar Propiedad
                </button>
              </div>
            ) : (
              activeProperties.slice(0, 5).map((prop) => {
                const tenant = prop.tenantId ? tenantMap.get(prop.tenantId) : null;
                return (
                  <div key={prop.id} className="flex items-center justify-between py-3">
                    <div>
                      <p className="text-sm font-semibold text-slate-900">{prop.name}</p>
                      <p className="text-xs text-slate-500">
                        {tenant ? `Inquilino: ${tenant.fullName}` : 'Sin inquilino asignado'} • Día {prop.dueDay}
                      </p>
                    </div>
                    <span className="font-mono text-xs font-bold text-slate-900">
                      {formatCurrencyDOP(prop.monthlyRentAmount)}
                    </span>
                  </div>
                );
              })
            )}
          </div>
        </div>

        {/* Payments Status Snapshot */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center justify-between border-b border-slate-100 pb-4">
            <h3 className="text-sm font-bold text-slate-900">Obligaciones de {formatPeriodSpanish(currentPeriod)}</h3>
            <button
              onClick={() => onNavigate('pagos')}
              className="flex items-center gap-1 text-xs font-semibold text-orange-600 hover:text-orange-700"
            >
              Gestionar Pagos <ArrowUpRight className="h-3.5 w-3.5" />
            </button>
          </div>

          <div className="mt-4 divide-y divide-slate-100">
            {currentMonthPayments.length === 0 ? (
              <div className="py-8 text-center">
                <CreditCard className="mx-auto h-8 w-8 text-slate-300" />
                <p className="mt-2 text-xs font-medium text-slate-500">
                  No hay obligaciones generadas para este período.
                </p>
                <button
                  onClick={onEnsurePayments}
                  disabled={isGenerating || activeProperties.length === 0}
                  className="mt-3 inline-flex items-center gap-1.5 rounded-lg bg-orange-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-orange-700 disabled:opacity-50"
                >
                  <CalendarClock className="h-3.5 w-3.5" />
                  Generar Obligaciones Ahora
                </button>
              </div>
            ) : (
              currentMonthPayments.slice(0, 5).map((pmt) => {
                const prop = propertyMap.get(pmt.propertyId);
                const isOverdue = isPaymentOverdue(pmt.dueDate, pmt.status, todayStr);
                const isDueToday = isPaymentDueToday(pmt.dueDate, pmt.status, todayStr);

                return (
                  <div key={pmt.id} className="flex items-center justify-between py-3">
                    <div>
                      <p className="text-sm font-semibold text-slate-900">
                        {prop?.name || 'Propiedad'}
                      </p>
                      <p className="text-xs text-slate-500">
                        Vence: {formatDateSpanish(pmt.dueDate)}
                      </p>
                    </div>

                    <div className="flex items-center gap-3">
                      <span className="font-mono text-xs font-bold text-slate-900">
                        {formatCurrencyDOP(pmt.amountDue)}
                      </span>
                      {pmt.status === 'paid' ? (
                        <span className="rounded-full bg-emerald-100 px-2.5 py-0.5 text-[11px] font-semibold text-emerald-800">
                          Pagado
                        </span>
                      ) : isOverdue ? (
                        <span className="rounded-full bg-rose-100 px-2.5 py-0.5 text-[11px] font-semibold text-rose-800">
                          Vencido
                        </span>
                      ) : isDueToday ? (
                        <span className="rounded-full bg-orange-100 px-2.5 py-0.5 text-[11px] font-semibold text-orange-800">
                          Vence Hoy
                        </span>
                      ) : (
                        <span className="rounded-full bg-amber-100 px-2.5 py-0.5 text-[11px] font-semibold text-amber-800">
                          Pendiente
                        </span>
                      )}
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </div>
      </div>
    </div>
  );
};
