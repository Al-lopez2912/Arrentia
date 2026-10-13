import React, { useState } from 'react';
import { 
  CreditCard, 
  CheckCircle2, 
  Clock, 
  AlertCircle, 
  Calendar, 
  Building2, 
  ChevronLeft, 
  ChevronRight, 
  Check, 
  FileText,
  Filter,
  RefreshCw,
  Search,
  Sparkles
} from 'lucide-react';
import { Payment, Property, Tenant } from '../types';
import { 
  formatCurrencyDOP, 
  formatDateSpanish, 
  formatPeriodSpanish, 
  isPaymentOverdue, 
  isPaymentDueToday,
  getCurrentPeriodSantoDomingo,
  getTodaySantoDomingo
} from '../utils/dateUtils';
import { ConfirmModal } from '../components/ConfirmModal';

interface PaymentsViewProps {
  payments: Payment[];
  properties: Property[];
  tenants: Tenant[];
  onMarkAsPaid: (payment: Payment) => Promise<void>;
  onEnsurePayments: (period: string) => Promise<void>;
  onRefresh: () => void;
  isGenerating?: boolean;
}

export const PaymentsView: React.FC<PaymentsViewProps> = ({
  payments,
  properties,
  tenants,
  onMarkAsPaid,
  onEnsurePayments,
  onRefresh,
  isGenerating = false,
}) => {
  const [selectedPeriod, setSelectedPeriod] = useState<string>(getCurrentPeriodSantoDomingo());
  const [statusFilter, setStatusFilter] = useState<'all' | 'pending' | 'paid' | 'overdue'>('all');
  const [propertyFilter, setPropertyFilter] = useState<string>('all');
  const [paymentToMarkPaid, setPaymentToMarkPaid] = useState<Payment | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [selectedPaymentDetail, setSelectedPaymentDetail] = useState<Payment | null>(null);

  const todayStr = getTodaySantoDomingo();
  const propertyMap = new Map(properties.map((p) => [p.id, p]));
  const tenantMap = new Map(tenants.map((t) => [t.id, t]));

  // Month navigation logic
  const handleNavigatePeriod = (direction: -1 | 1) => {
    const [yearStr, monthStr] = selectedPeriod.split('-');
    let year = parseInt(yearStr, 10);
    let month = parseInt(monthStr, 10) + direction;

    if (month > 12) {
      month = 1;
      year += 1;
    } else if (month < 1) {
      month = 12;
      year -= 1;
    }

    const newPeriod = `${year}-${String(month).padStart(2, '0')}`;
    setSelectedPeriod(newPeriod);
  };

  const periodPayments = payments.filter((p) => p.period === selectedPeriod);

  const filteredPayments = periodPayments.filter((p) => {
    // Status filter
    const isOverdue = isPaymentOverdue(p.dueDate, p.status, todayStr);
    if (statusFilter === 'pending' && p.status !== 'pending') return false;
    if (statusFilter === 'paid' && p.status !== 'paid') return false;
    if (statusFilter === 'overdue' && !isOverdue) return false;

    // Property filter
    if (propertyFilter !== 'all' && p.propertyId !== propertyFilter) return false;

    return true;
  });

  // Totals for this period
  const totalAmountDue = periodPayments.reduce((acc, p) => acc + p.amountDue, 0);
  const totalPaid = periodPayments.filter((p) => p.status === 'paid').reduce((acc, p) => acc + p.amountDue, 0);
  const totalPending = periodPayments.filter((p) => p.status === 'pending').reduce((acc, p) => acc + p.amountDue, 0);

  const handleConfirmMarkAsPaid = async () => {
    if (!paymentToMarkPaid) return;
    try {
      setIsSubmitting(true);
      await onMarkAsPaid(paymentToMarkPaid);
      setPaymentToMarkPaid(null);
    } catch (err) {
      console.error('Error marking payment as paid:', err);
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Top Header & Month Selector */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-xl font-bold text-slate-900 tracking-tight sm:text-2xl">
            Obligaciones y Control de Pagos
          </h2>
          <p className="text-sm text-slate-500 mt-1">
            Registro mensual determinístico por propiedad. Registro y auditoría de cobros en DOP.
          </p>
        </div>

        <div className="flex items-center gap-2">
          <button
            onClick={onRefresh}
            className="flex items-center gap-1.5 rounded-lg border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50 shadow-2xs"
            title="Recargar"
          >
            <RefreshCw className="h-3.5 w-3.5 text-slate-500" />
            Recargar
          </button>
          <button
            onClick={() => onEnsurePayments(selectedPeriod)}
            disabled={isGenerating}
            className="flex items-center gap-1.5 rounded-lg bg-orange-600 px-3.5 py-2 text-xs font-semibold text-white shadow-2xs hover:bg-orange-700 disabled:opacity-50"
          >
            <Sparkles className="h-3.5 w-3.5" />
            {isGenerating ? 'Generando...' : `Generar Pagos (${selectedPeriod})`}
          </button>
        </div>
      </div>

      {/* Month Navigator Banner */}
      <div className="flex flex-wrap items-center justify-between gap-4 rounded-xl border border-slate-200 bg-white p-4 shadow-2xs">
        <div className="flex items-center gap-2">
          <button
            onClick={() => handleNavigatePeriod(-1)}
            className="rounded-lg border border-slate-200 p-2 text-slate-600 hover:bg-slate-50"
            title="Mes anterior"
          >
            <ChevronLeft className="h-4 w-4" />
          </button>

          <div className="flex items-center gap-2 px-2">
            <Calendar className="h-4 w-4 text-orange-600" />
            <span className="text-base font-bold text-slate-900">
              {formatPeriodSpanish(selectedPeriod)}
            </span>
            <span className="font-mono text-xs text-slate-400">({selectedPeriod})</span>
          </div>

          <button
            onClick={() => handleNavigatePeriod(1)}
            className="rounded-lg border border-slate-200 p-2 text-slate-600 hover:bg-slate-50"
            title="Mes siguiente"
          >
            <ChevronRight className="h-4 w-4" />
          </button>

          {selectedPeriod !== getCurrentPeriodSantoDomingo() && (
            <button
              onClick={() => setSelectedPeriod(getCurrentPeriodSantoDomingo())}
              className="ml-2 rounded-md bg-slate-100 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-200"
            >
              Ir a Mes Actual
            </button>
          )}
        </div>

        {/* Monthly Summary Badges */}
        <div className="flex flex-wrap items-center gap-3 text-xs">
          <div className="rounded-lg bg-slate-50 px-3 py-1.5 border border-slate-100">
            <span className="text-slate-500">Total Esperado: </span>
            <span className="font-mono font-bold text-slate-900">{formatCurrencyDOP(totalAmountDue)}</span>
          </div>
          <div className="rounded-lg bg-emerald-50 px-3 py-1.5 border border-emerald-100 text-emerald-800">
            <span>Cobrado: </span>
            <span className="font-mono font-bold">{formatCurrencyDOP(totalPaid)}</span>
          </div>
          <div className="rounded-lg bg-amber-50 px-3 py-1.5 border border-amber-100 text-amber-900">
            <span>Pendiente: </span>
            <span className="font-mono font-bold">{formatCurrencyDOP(totalPending)}</span>
          </div>
        </div>
      </div>

      {/* Filters Bar */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        {/* Status Pill Filters */}
        <div className="flex flex-wrap gap-1.5">
          <button
            onClick={() => setStatusFilter('all')}
            className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-colors ${
              statusFilter === 'all'
                ? 'bg-slate-900 text-white'
                : 'bg-white border border-slate-200 text-slate-600 hover:bg-slate-50'
            }`}
          >
            Todos ({periodPayments.length})
          </button>
          <button
            onClick={() => setStatusFilter('pending')}
            className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-colors ${
              statusFilter === 'pending'
                ? 'bg-amber-600 text-white'
                : 'bg-white border border-slate-200 text-slate-600 hover:bg-slate-50'
            }`}
          >
            Pendientes ({periodPayments.filter((p) => p.status === 'pending').length})
          </button>
          <button
            onClick={() => setStatusFilter('overdue')}
            className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-colors ${
              statusFilter === 'overdue'
                ? 'bg-rose-600 text-white'
                : 'bg-white border border-slate-200 text-slate-600 hover:bg-slate-50'
            }`}
          >
            Vencidos ({periodPayments.filter((p) => isPaymentOverdue(p.dueDate, p.status, todayStr)).length})
          </button>
          <button
            onClick={() => setStatusFilter('paid')}
            className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-colors ${
              statusFilter === 'paid'
                ? 'bg-emerald-600 text-white'
                : 'bg-white border border-slate-200 text-slate-600 hover:bg-slate-50'
            }`}
          >
            Pagados ({periodPayments.filter((p) => p.status === 'paid').length})
          </button>
        </div>

        {/* Property Dropdown Filter */}
        <div className="flex items-center gap-2">
          <span className="text-xs text-slate-500 font-medium">Propiedad:</span>
          <select
            value={propertyFilter}
            onChange={(e) => setPropertyFilter(e.target.value)}
            className="rounded-lg border border-slate-200 bg-white px-3 py-1.5 text-xs text-slate-800 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
          >
            <option value="all">Todas las propiedades</option>
            {properties.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </select>
        </div>
      </div>

      {/* Payments Table / List */}
      {filteredPayments.length === 0 ? (
        <div className="rounded-xl border border-slate-200 bg-white p-12 text-center shadow-2xs">
          <CreditCard className="mx-auto h-12 w-12 text-slate-300" />
          <h3 className="mt-3 text-sm font-bold text-slate-800">
            No hay obligaciones para los filtros seleccionados
          </h3>
          <p className="mt-1 text-xs text-slate-500">
            {periodPayments.length === 0
              ? `No existen registros de cobro para el período ${selectedPeriod}. Puedes generarlos con el botón superior.`
              : 'Intenta cambiar los filtros de estado o propiedad.'}
          </p>
          {periodPayments.length === 0 && (
            <button
              onClick={() => onEnsurePayments(selectedPeriod)}
              disabled={isGenerating}
              className="mt-4 inline-flex items-center gap-1.5 rounded-lg bg-orange-600 px-3.5 py-2 text-xs font-semibold text-white hover:bg-orange-700 disabled:opacity-50"
            >
              <Sparkles className="h-3.5 w-3.5" />
              Generar Obligaciones para {selectedPeriod}
            </button>
          )}
        </div>
      ) : (
        <div className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-2xs">
          <div className="overflow-x-auto">
            <table className="w-full text-left text-xs">
              <thead className="border-b border-slate-200 bg-slate-50 text-[11px] font-bold uppercase tracking-wider text-slate-500">
                <tr>
                  <th className="px-5 py-3.5">Propiedad</th>
                  <th className="px-5 py-3.5">Inquilino</th>
                  <th className="px-5 py-3.5">Importe (DOP)</th>
                  <th className="px-5 py-3.5">Vencimiento</th>
                  <th className="px-5 py-3.5">Estado</th>
                  <th className="px-5 py-3.5">Registro de Pago</th>
                  <th className="px-5 py-3.5 text-right">Acción</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100 text-slate-700">
                {filteredPayments.map((pmt) => {
                  const prop = propertyMap.get(pmt.propertyId);
                  const tenant = pmt.tenantId ? tenantMap.get(pmt.tenantId) : null;
                  const isOverdue = isPaymentOverdue(pmt.dueDate, pmt.status, todayStr);
                  const isDueToday = isPaymentDueToday(pmt.dueDate, pmt.status, todayStr);

                  return (
                    <tr key={pmt.id} className="hover:bg-slate-50/70 transition-colors">
                      <td className="px-5 py-4 font-semibold text-slate-900">
                        <div className="flex items-center gap-2">
                          <Building2 className="h-4 w-4 text-slate-400 shrink-0" />
                          <span>{prop?.name || 'Propiedad'}</span>
                        </div>
                      </td>

                      <td className="px-5 py-4">
                        {tenant ? (
                          <div>
                            <p className="font-medium text-slate-900">{tenant.fullName}</p>
                            <p className="text-[11px] text-slate-400">{tenant.phone}</p>
                          </div>
                        ) : (
                          <span className="italic text-slate-400">Sin inquilino</span>
                        )}
                      </td>

                      <td className="px-5 py-4 font-mono font-bold text-slate-900">
                        {formatCurrencyDOP(pmt.amountDue)}
                      </td>

                      <td className="px-5 py-4">
                        <div className="flex items-center gap-1.5">
                          <span>{formatDateSpanish(pmt.dueDate)}</span>
                          {isDueToday && (
                            <span className="rounded-md bg-orange-100 px-1.5 py-0.5 text-[10px] font-bold text-orange-800">
                              Hoy
                            </span>
                          )}
                        </div>
                      </td>

                      <td className="px-5 py-4">
                        {pmt.status === 'paid' ? (
                          <span className="inline-flex items-center gap-1 rounded-full bg-emerald-100 px-2.5 py-0.5 text-[11px] font-semibold text-emerald-800">
                            <CheckCircle2 className="h-3 w-3" />
                            Pagado
                          </span>
                        ) : isOverdue ? (
                          <span className="inline-flex items-center gap-1 rounded-full bg-rose-100 px-2.5 py-0.5 text-[11px] font-semibold text-rose-800">
                            <AlertCircle className="h-3 w-3" />
                            Vencido
                          </span>
                        ) : (
                          <span className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2.5 py-0.5 text-[11px] font-semibold text-amber-800">
                            <Clock className="h-3 w-3" />
                            Pendiente
                          </span>
                        )}
                      </td>

                      <td className="px-5 py-4 text-slate-500">
                        {pmt.paidAt ? (
                          <div title={pmt.paidAt}>
                            <p className="font-medium text-slate-700">
                              {formatDateSpanish(pmt.paidAt.substring(0, 10))}
                            </p>
                            <p className="text-[10px] text-slate-400 font-mono">
                              {new Date(pmt.paidAt).toLocaleTimeString('es-DO', { hour: '2-digit', minute: '2-digit' })} AST
                            </p>
                          </div>
                        ) : (
                          <span className="text-slate-400">—</span>
                        )}
                      </td>

                      <td className="px-5 py-4 text-right">
                        {pmt.status === 'pending' ? (
                          <button
                            onClick={() => setPaymentToMarkPaid(pmt)}
                            className="inline-flex items-center gap-1.5 rounded-lg bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white shadow-2xs hover:bg-emerald-700 transition-colors"
                          >
                            <Check className="h-3.5 w-3.5" />
                            Marcar Pagado
                          </button>
                        ) : (
                          <button
                            onClick={() => setSelectedPaymentDetail(pmt)}
                            className="inline-flex items-center gap-1 text-xs font-semibold text-slate-500 hover:text-slate-800"
                          >
                            <FileText className="h-3.5 w-3.5" />
                            Detalles
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Confirmation Modal to Mark as Paid */}
      {paymentToMarkPaid && (
        <ConfirmModal
          isOpen={Boolean(paymentToMarkPaid)}
          title="Confirmar Cobro de Alquiler"
          message={`¿Confirmas que has recibido el pago de ${formatCurrencyDOP(paymentToMarkPaid.amountDue)} correspondiente a la propiedad "${propertyMap.get(paymentToMarkPaid.propertyId)?.name || 'Propiedad'}" por el período ${formatPeriodSpanish(paymentToMarkPaid.period)}? Esta acción registrará la marca de tiempo oficial del servidor y el estado se bloqueará de forma inmutable.`}
          confirmLabel="Sí, Registrar como Pagado"
          isLoading={isSubmitting}
          onConfirm={handleConfirmMarkAsPaid}
          onCancel={() => setPaymentToMarkPaid(null)}
        />
      )}

      {/* Payment Detail Modal */}
      {selectedPaymentDetail && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-900/40 backdrop-blur-xs">
          <div className="w-full max-w-md rounded-xl border border-slate-200 bg-white p-6 shadow-xl">
            <h3 className="text-base font-bold text-slate-900">Detalles del Comprobante</h3>
            <p className="text-xs text-slate-500 mt-0.5">
              Identificador único: <span className="font-mono text-slate-700">{selectedPaymentDetail.id}</span>
            </p>

            <div className="mt-4 space-y-3 rounded-lg bg-slate-50 p-4 text-xs">
              <div className="flex justify-between border-b border-slate-200/60 pb-2">
                <span className="text-slate-500">Propiedad:</span>
                <span className="font-bold text-slate-900">
                  {propertyMap.get(selectedPaymentDetail.propertyId)?.name}
                </span>
              </div>
              <div className="flex justify-between border-b border-slate-200/60 pb-2">
                <span className="text-slate-500">Período:</span>
                <span className="font-bold text-slate-900">
                  {formatPeriodSpanish(selectedPaymentDetail.period)}
                </span>
              </div>
              <div className="flex justify-between border-b border-slate-200/60 pb-2">
                <span className="text-slate-500">Monto:</span>
                <span className="font-mono font-bold text-slate-900">
                  {formatCurrencyDOP(selectedPaymentDetail.amountDue)}
                </span>
              </div>
              <div className="flex justify-between border-b border-slate-200/60 pb-2">
                <span className="text-slate-500">Fecha de Vencimiento:</span>
                <span className="font-bold text-slate-900">
                  {formatDateSpanish(selectedPaymentDetail.dueDate)}
                </span>
              </div>
              <div className="flex justify-between border-b border-slate-200/60 pb-2">
                <span className="text-slate-500">Estado:</span>
                <span className="font-bold text-emerald-700">Pagado</span>
              </div>
              <div className="flex justify-between">
                <span className="text-slate-500">Fecha y Hora de Cobro:</span>
                <span className="font-bold text-slate-900 font-mono">
                  {selectedPaymentDetail.paidAt ? new Date(selectedPaymentDetail.paidAt).toLocaleString('es-DO', { timeZone: 'America/Santo_Domingo' }) : 'N/A'}
                </span>
              </div>
            </div>

            <div className="mt-5 flex justify-end">
              <button
                onClick={() => setSelectedPaymentDetail(null)}
                className="rounded-lg bg-slate-900 px-4 py-2 text-xs font-semibold text-white hover:bg-slate-800"
              >
                Cerrar
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};
