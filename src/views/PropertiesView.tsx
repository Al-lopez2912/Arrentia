import React, { useState } from 'react';
import { 
  Building2, 
  Plus, 
  Search, 
  Edit2, 
  Archive, 
  Calendar, 
  User as UserIcon, 
  MapPin, 
  X,
  History,
  CheckCircle2,
  Clock,
  AlertCircle
} from 'lucide-react';
import { Property, Tenant, Payment } from '../types';
import { 
  formatCurrencyDOP, 
  formatDateSpanish, 
  formatPeriodSpanish,
  getTodaySantoDomingo,
  isPaymentOverdue
} from '../utils/dateUtils';
import { ConfirmModal } from '../components/ConfirmModal';

interface PropertiesViewProps {
  properties: Property[];
  tenants: Tenant[];
  payments: Payment[];
  onCreateProperty: (data: Omit<Property, 'id' | 'ownerUid' | 'createdAt' | 'updatedAt'>) => Promise<void>;
  onUpdateProperty: (id: string, data: Partial<Property>) => Promise<void>;
  onArchiveProperty: (id: string) => Promise<void>;
}

export const PropertiesView: React.FC<PropertiesViewProps> = ({
  properties,
  tenants,
  payments,
  onCreateProperty,
  onUpdateProperty,
  onArchiveProperty,
}) => {
  const [searchTerm, setSearchTerm] = useState('');
  const [showArchived, setShowArchived] = useState(false);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [editingProperty, setEditingProperty] = useState<Property | null>(null);
  const [selectedPropertyDetails, setSelectedPropertyDetails] = useState<Property | null>(null);
  const [archiveTargetId, setArchiveTargetId] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  // Form states
  const [formName, setFormName] = useState('');
  const [formAddress, setFormAddress] = useState('');
  const [formRent, setFormRent] = useState<number | ''>('');
  const [formDueDay, setFormDueDay] = useState<number>(1);
  const [formTenantId, setFormTenantId] = useState<string>('');
  const [formStartDate, setFormStartDate] = useState(getTodaySantoDomingo());
  const [formEndDate, setFormEndDate] = useState('');

  const todayStr = getTodaySantoDomingo();
  const tenantMap = new Map(tenants.map((t) => [t.id, t]));

  // Active tenants available for assignment (or already assigned to this property)
  const availableTenants = tenants.filter(
    (t) => t.active && (!t.propertyId || (editingProperty && t.propertyId === editingProperty.id))
  );

  const filteredProperties = properties.filter((p) => {
    const matchesSearch =
      p.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
      p.address.toLowerCase().includes(searchTerm.toLowerCase());
    const matchesArchive = showArchived ? true : p.active;
    return matchesSearch && matchesArchive;
  });

  const handleOpenCreateModal = () => {
    setEditingProperty(null);
    setFormName('');
    setFormAddress('');
    setFormRent('');
    setFormDueDay(1);
    setFormTenantId('');
    setFormStartDate(getTodaySantoDomingo());
    setFormEndDate('');
    setFormError(null);
    setIsModalOpen(true);
  };

  const handleOpenEditModal = (prop: Property) => {
    setEditingProperty(prop);
    setFormName(prop.name);
    setFormAddress(prop.address);
    setFormRent(prop.monthlyRentAmount);
    setFormDueDay(prop.dueDay);
    setFormTenantId(prop.tenantId || '');
    setFormStartDate(prop.leaseStartDate);
    setFormEndDate(prop.leaseEndDate || '');
    setFormError(null);
    setIsModalOpen(true);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setFormError(null);

    // Strict Validations
    if (!formName.trim()) {
      setFormError('El nombre de la propiedad es requerido.');
      return;
    }
    if (!formAddress.trim()) {
      setFormError('La dirección de la propiedad es requerida.');
      return;
    }
    const rentNum = typeof formRent === 'number' ? formRent : parseInt(String(formRent), 10);
    if (!rentNum || isNaN(rentNum) || rentNum <= 0) {
      setFormError('El monto de renta mensual debe ser un número entero positivo en DOP.');
      return;
    }
    if (formDueDay < 1 || formDueDay > 31) {
      setFormError('El día de vencimiento debe estar entre 1 y 31.');
      return;
    }
    if (!formStartDate) {
      setFormError('La fecha de inicio de contrato es requerida.');
      return;
    }
    if (formEndDate && formEndDate < formStartDate) {
      setFormError('La fecha de fin de contrato no puede ser anterior a la fecha de inicio.');
      return;
    }

    try {
      setIsSubmitting(true);
      const payload = {
        name: formName.trim(),
        address: formAddress.trim(),
        monthlyRentAmount: Math.round(rentNum),
        dueDay: formDueDay,
        tenantId: formTenantId ? formTenantId : null,
        leaseStartDate: formStartDate,
        leaseEndDate: formEndDate ? formEndDate : null,
        active: true,
      };

      if (editingProperty) {
        await onUpdateProperty(editingProperty.id, payload);
      } else {
        await onCreateProperty(payload);
      }

      setIsModalOpen(false);
    } catch (err: any) {
      setFormError(err.message || 'Error al guardar la propiedad.');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleConfirmArchive = async () => {
    if (!archiveTargetId) return;
    try {
      setIsSubmitting(true);
      await onArchiveProperty(archiveTargetId);
      setArchiveTargetId(null);
      if (selectedPropertyDetails?.id === archiveTargetId) {
        setSelectedPropertyDetails(null);
      }
    } catch (err) {
      console.error('Error archiving property:', err);
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Action Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-xl font-bold text-slate-900 tracking-tight sm:text-2xl">
            Gestión de Propiedades
          </h2>
          <p className="text-sm text-slate-500 mt-1">
            Administra las unidades en alquiler, asignación de inquilinos y montos mensuales en DOP.
          </p>
        </div>

        <button
          onClick={handleOpenCreateModal}
          className="flex items-center justify-center gap-2 rounded-lg bg-orange-600 px-4 py-2.5 text-xs font-semibold text-white shadow-2xs hover:bg-orange-700 transition-colors"
        >
          <Plus className="h-4 w-4" />
          Nueva Propiedad
        </button>
      </div>

      {/* Filters & Search */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="relative flex-1 max-w-md">
          <Search className="pointer-events-none absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
          <input
            type="text"
            placeholder="Buscar por nombre o dirección..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="w-full rounded-lg border border-slate-200 bg-white py-2 pl-9 pr-3 text-xs text-slate-800 placeholder-slate-400 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
          >
          </input>
        </div>

        <label className="flex items-center gap-2 text-xs font-medium text-slate-600 cursor-pointer">
          <input
            type="checkbox"
            checked={showArchived}
            onChange={(e) => setShowArchived(e.target.checked)}
            className="rounded-sm border-slate-300 text-orange-600 focus:ring-orange-500"
          />
          Mostrar archivadas
        </label>
      </div>

      {/* Property Cards Grid */}
      {filteredProperties.length === 0 ? (
        <div className="rounded-xl border border-slate-200 bg-white p-12 text-center shadow-2xs">
          <Building2 className="mx-auto h-12 w-12 text-slate-300" />
          <h3 className="mt-3 text-sm font-bold text-slate-800">No se encontraron propiedades</h3>
          <p className="mt-1 text-xs text-slate-500">
            {searchTerm ? 'Prueba con otros términos de búsqueda.' : 'Crea tu primera propiedad para empezar a gestionar alquileres.'}
          </p>
          {!searchTerm && (
            <button
              onClick={handleOpenCreateModal}
              className="mt-4 inline-flex items-center gap-1.5 rounded-lg bg-orange-600 px-3.5 py-2 text-xs font-semibold text-white hover:bg-orange-700"
            >
              <Plus className="h-3.5 w-3.5" />
              Crear Propiedad
            </button>
          )}
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
          {filteredProperties.map((prop) => {
            const tenant = prop.tenantId ? tenantMap.get(prop.tenantId) : null;
            const propertyPayments = payments.filter((p) => p.propertyId === prop.id);
            const pendingCount = propertyPayments.filter((p) => p.status === 'pending').length;

            return (
              <div
                key={prop.id}
                className={`flex flex-col justify-between rounded-xl border bg-white p-5 shadow-2xs transition-all ${
                  prop.active ? 'border-slate-200 hover:border-slate-300' : 'border-slate-200 bg-slate-50/60 opacity-80'
                }`}
              >
                <div>
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <h3 className="text-base font-bold text-slate-900 leading-snug">{prop.name}</h3>
                      <p className="flex items-center gap-1 text-xs text-slate-500 mt-1">
                        <MapPin className="h-3.5 w-3.5 shrink-0 text-slate-400" />
                        <span className="truncate">{prop.address}</span>
                      </p>
                    </div>
                    <span
                      className={`shrink-0 rounded-full px-2.5 py-0.5 text-[11px] font-semibold ${
                        prop.active
                          ? 'bg-emerald-100 text-emerald-800'
                          : 'bg-slate-200 text-slate-700'
                      }`}
                    >
                      {prop.active ? 'Activa' : 'Archivada'}
                    </span>
                  </div>

                  {/* Financial & Due Day Info */}
                  <div className="mt-4 grid grid-cols-2 gap-2 rounded-lg bg-slate-50 p-3">
                    <div>
                      <span className="text-[11px] font-medium text-slate-500">Renta Mensual</span>
                      <p className="font-mono text-sm font-bold text-slate-900">
                        {formatCurrencyDOP(prop.monthlyRentAmount)}
                      </p>
                    </div>
                    <div>
                      <span className="text-[11px] font-medium text-slate-500">Día de Pago</span>
                      <p className="font-mono text-sm font-bold text-orange-700">
                        Día {prop.dueDay} de cada mes
                      </p>
                    </div>
                  </div>

                  {/* Tenant Association */}
                  <div className="mt-3 flex items-center gap-2 text-xs">
                    <UserIcon className="h-3.5 w-3.5 text-slate-400 shrink-0" />
                    <span className="text-slate-600">Inquilino:</span>
                    {tenant ? (
                      <span className="font-semibold text-slate-800 truncate">{tenant.fullName}</span>
                    ) : (
                      <span className="italic text-slate-400">Sin asignar</span>
                    )}
                  </div>

                  {/* Lease dates */}
                  <div className="mt-1 flex items-center gap-2 text-xs text-slate-500">
                    <Calendar className="h-3.5 w-3.5 text-slate-400 shrink-0" />
                    <span>Contrato: {formatDateSpanish(prop.leaseStartDate)}</span>
                    {prop.leaseEndDate && (
                      <span>— {formatDateSpanish(prop.leaseEndDate)}</span>
                    )}
                  </div>
                </div>

                {/* Card Actions */}
                <div className="mt-5 flex items-center justify-between border-t border-slate-100 pt-3">
                  <button
                    onClick={() => setSelectedPropertyDetails(prop)}
                    className="flex items-center gap-1 text-xs font-semibold text-orange-600 hover:text-orange-700"
                  >
                    <History className="h-3.5 w-3.5" />
                    Historial ({propertyPayments.length})
                  </button>

                  <div className="flex items-center gap-1">
                    <button
                      onClick={() => handleOpenEditModal(prop)}
                      className="rounded-md p-1.5 text-slate-500 hover:bg-slate-100 hover:text-slate-800"
                      title="Editar propiedad"
                    >
                      <Edit2 className="h-3.5 w-3.5" />
                    </button>
                    {prop.active && (
                      <button
                        onClick={() => setArchiveTargetId(prop.id)}
                        className="rounded-md p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                        title="Archivar propiedad"
                      >
                        <Archive className="h-3.5 w-3.5" />
                      </button>
                    )}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* Property Details & Historical Payments Drawer/Modal */}
      {selectedPropertyDetails && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-900/40 backdrop-blur-xs">
          <div className="w-full max-w-2xl max-h-[90vh] flex flex-col rounded-xl border border-slate-200 bg-white p-6 shadow-xl overflow-hidden">
            <div className="flex items-start justify-between border-b border-slate-100 pb-4">
              <div>
                <h3 className="text-lg font-bold text-slate-900">{selectedPropertyDetails.name}</h3>
                <p className="text-xs text-slate-500">{selectedPropertyDetails.address}</p>
              </div>
              <button
                onClick={() => setSelectedPropertyDetails(null)}
                className="rounded-lg p-1 text-slate-400 hover:bg-slate-100"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            <div className="mt-4 flex-1 overflow-y-auto space-y-4 pr-1">
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 rounded-lg bg-slate-50 p-3 text-xs">
                <div>
                  <span className="text-slate-500">Renta Mensual:</span>
                  <p className="font-mono font-bold text-slate-900">
                    {formatCurrencyDOP(selectedPropertyDetails.monthlyRentAmount)}
                  </p>
                </div>
                <div>
                  <span className="text-slate-500">Día de Vencimiento:</span>
                  <p className="font-bold text-slate-900">Día {selectedPropertyDetails.dueDay}</p>
                </div>
                <div>
                  <span className="text-slate-500">Inquilino Actual:</span>
                  <p className="font-bold text-slate-900">
                    {selectedPropertyDetails.tenantId && tenantMap.get(selectedPropertyDetails.tenantId)
                      ? tenantMap.get(selectedPropertyDetails.tenantId)!.fullName
                      : 'Ninguno'}
                  </p>
                </div>
              </div>

              <div>
                <h4 className="text-xs font-bold uppercase tracking-wider text-slate-500 mb-2">
                  Historial de Obligaciones y Pagos
                </h4>
                {(() => {
                  const history = payments
                    .filter((p) => p.propertyId === selectedPropertyDetails.id)
                    .sort((a, b) => b.period.localeCompare(a.period));

                  if (history.length === 0) {
                    return (
                      <p className="text-xs text-slate-500 italic py-4 text-center">
                        No hay registros de pagos para esta propiedad.
                      </p>
                    );
                  }

                  return (
                    <div className="divide-y divide-slate-100 border border-slate-200 rounded-lg overflow-hidden">
                      {history.map((pmt) => {
                        const isOverdue = isPaymentOverdue(pmt.dueDate, pmt.status, todayStr);
                        return (
                          <div key={pmt.id} className="flex items-center justify-between p-3 text-xs">
                            <div>
                              <p className="font-semibold text-slate-800">
                                {formatPeriodSpanish(pmt.period)}
                              </p>
                              <p className="text-slate-500 text-[11px]">
                                Vencimiento: {formatDateSpanish(pmt.dueDate)}
                                {pmt.paidAt && ` • Pagado el: ${formatDateSpanish(pmt.paidAt.substring(0, 10))}`}
                              </p>
                            </div>
                            <div className="flex items-center gap-3">
                              <span className="font-mono font-bold text-slate-900">
                                {formatCurrencyDOP(pmt.amountDue)}
                              </span>
                              {pmt.status === 'paid' ? (
                                <span className="flex items-center gap-1 rounded-full bg-emerald-100 px-2 py-0.5 text-[11px] font-semibold text-emerald-800">
                                  <CheckCircle2 className="h-3 w-3" /> Pagado
                                </span>
                              ) : isOverdue ? (
                                <span className="flex items-center gap-1 rounded-full bg-rose-100 px-2 py-0.5 text-[11px] font-semibold text-rose-800">
                                  <AlertCircle className="h-3 w-3" /> Vencido
                                </span>
                              ) : (
                                <span className="flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-[11px] font-semibold text-amber-800">
                                  <Clock className="h-3 w-3" /> Pendiente
                                </span>
                              )}
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  );
                })()}
              </div>
            </div>

            <div className="mt-4 pt-3 border-t border-slate-100 flex justify-end">
              <button
                onClick={() => setSelectedPropertyDetails(null)}
                className="rounded-lg border border-slate-200 px-4 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50"
              >
                Cerrar
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Create / Edit Property Modal */}
      {isModalOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-900/40 backdrop-blur-xs">
          <div className="w-full max-w-lg rounded-xl border border-slate-200 bg-white p-6 shadow-xl">
            <div className="flex items-center justify-between border-b border-slate-100 pb-3">
              <h3 className="text-base font-bold text-slate-900">
                {editingProperty ? 'Editar Propiedad' : 'Registrar Nueva Propiedad'}
              </h3>
              <button
                onClick={() => setIsModalOpen(false)}
                className="rounded-lg p-1 text-slate-400 hover:bg-slate-100"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            {formError && (
              <div className="mt-3 rounded-lg bg-rose-50 p-2.5 text-xs text-rose-700 border border-rose-200">
                {formError}
              </div>
            )}

            <form onSubmit={handleSubmit} className="mt-4 space-y-4">
              <div>
                <label className="block text-xs font-semibold text-slate-700">
                  Nombre de la propiedad *
                </label>
                <input
                  type="text"
                  placeholder="Ej. Casa A, Apto 3B, Villa Palmera"
                  value={formName}
                  onChange={(e) => setFormName(e.target.value)}
                  required
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-700">
                  Dirección completa *
                </label>
                <input
                  type="text"
                  placeholder="Calle, Número, Sector, Ciudad"
                  value={formAddress}
                  onChange={(e) => setFormAddress(e.target.value)}
                  required
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-semibold text-slate-700">
                    Renta Mensual (RD$) *
                  </label>
                  <input
                    type="number"
                    min="1"
                    step="1"
                    placeholder="25000"
                    value={formRent}
                    onChange={(e) => setFormRent(e.target.value === '' ? '' : parseInt(e.target.value, 10))}
                    required
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 font-mono focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                  />
                  <span className="text-[10px] text-slate-400">Pesos dominicanos enteros</span>
                </div>

                <div>
                  <label className="block text-xs font-semibold text-slate-700">
                    Día de pago (1 - 31) *
                  </label>
                  <input
                    type="number"
                    min="1"
                    max="31"
                    value={formDueDay}
                    onChange={(e) => setFormDueDay(parseInt(e.target.value, 10) || 1)}
                    required
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 font-mono focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                  />
                  <span className="text-[10px] text-slate-400">Si el mes tiene menos días se ajusta al último</span>
                </div>
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-700">
                  Inquilino asignado
                </label>
                <select
                  value={formTenantId}
                  onChange={(e) => setFormTenantId(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                >
                  <option value="">-- Sin inquilino (vacante) --</option>
                  {availableTenants.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.fullName} ({t.phone})
                    </option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="block text-xs font-semibold text-slate-700">
                    Inicio de contrato *
                  </label>
                  <input
                    type="date"
                    value={formStartDate}
                    onChange={(e) => setFormStartDate(e.target.value)}
                    required
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                  />
                </div>

                <div>
                  <label className="block text-xs font-semibold text-slate-700">
                    Fin de contrato (opcional)
                  </label>
                  <input
                    type="date"
                    value={formEndDate}
                    onChange={(e) => setFormEndDate(e.target.value)}
                    className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                  />
                </div>
              </div>

              <div className="mt-6 flex items-center justify-end gap-3 pt-3 border-t border-slate-100">
                <button
                  type="button"
                  onClick={() => setIsModalOpen(false)}
                  disabled={isSubmitting}
                  className="rounded-lg border border-slate-200 px-4 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50"
                >
                  Cancelar
                </button>
                <button
                  type="submit"
                  disabled={isSubmitting}
                  className="rounded-lg bg-orange-600 px-4 py-2 text-xs font-semibold text-white hover:bg-orange-700 disabled:opacity-50 shadow-2xs"
                >
                  {isSubmitting ? 'Guardando...' : editingProperty ? 'Actualizar Propiedad' : 'Guardar Propiedad'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Archive Confirmation Modal */}
      <ConfirmModal
        isOpen={Boolean(archiveTargetId)}
        title="Archivar Propiedad"
        message="¿Estás seguro de que deseas archivar esta propiedad? La propiedad dejará de generar nuevas obligaciones mensuales, pero todo su historial de cobros y pagos se preservará intacto."
        confirmLabel="Archivar Propiedad"
        isDestructive
        isLoading={isSubmitting}
        onConfirm={handleConfirmArchive}
        onCancel={() => setArchiveTargetId(null)}
      />
    </div>
  );
};
