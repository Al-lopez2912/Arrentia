import React, { useState } from 'react';
import { 
  Users, 
  Plus, 
  Search, 
  Edit2, 
  UserMinus, 
  Phone, 
  Mail, 
  Building2, 
  FileText,
  X,
  CheckCircle2,
  AlertCircle
} from 'lucide-react';
import { Tenant, Property } from '../types';
import { ConfirmModal } from '../components/ConfirmModal';

interface TenantsViewProps {
  tenants: Tenant[];
  properties: Property[];
  onCreateTenant: (data: Omit<Tenant, 'id' | 'ownerUid' | 'createdAt' | 'updatedAt'>) => Promise<void>;
  onUpdateTenant: (id: string, data: Partial<Tenant>) => Promise<void>;
  onDeactivateTenant: (id: string) => Promise<void>;
  onAssignPropertyTenant: (propertyId: string, tenantId: string | null) => Promise<void>;
}

export const TenantsView: React.FC<TenantsViewProps> = ({
  tenants,
  properties,
  onCreateTenant,
  onUpdateTenant,
  onDeactivateTenant,
  onAssignPropertyTenant,
}) => {
  const [searchTerm, setSearchTerm] = useState('');
  const [showInactive, setShowInactive] = useState(false);
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [editingTenant, setEditingTenant] = useState<Tenant | null>(null);
  const [deactivateTargetId, setDeactivateTargetId] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);

  // Form states
  const [formFullName, setFormFullName] = useState('');
  const [formPhone, setFormPhone] = useState('');
  const [formEmail, setFormEmail] = useState('');
  const [formPropertyId, setFormPropertyId] = useState('');
  const [formNotes, setFormNotes] = useState('');

  const propertyMap = new Map(properties.map((p) => [p.id, p]));

  // Active properties available to be assigned (vacant or assigned to current tenant)
  const availableProperties = properties.filter(
    (p) => p.active && (!p.tenantId || (editingTenant && p.tenantId === editingTenant.id))
  );

  const filteredTenants = tenants.filter((t) => {
    const matchesSearch =
      t.fullName.toLowerCase().includes(searchTerm.toLowerCase()) ||
      t.phone.toLowerCase().includes(searchTerm.toLowerCase()) ||
      (t.email && t.email.toLowerCase().includes(searchTerm.toLowerCase()));
    const matchesActive = showInactive ? true : t.active;
    return matchesSearch && matchesActive;
  });

  const handleOpenCreateModal = () => {
    setEditingTenant(null);
    setFormFullName('');
    setFormPhone('');
    setFormEmail('');
    setFormPropertyId('');
    setFormNotes('');
    setFormError(null);
    setIsModalOpen(true);
  };

  const handleOpenEditModal = (t: Tenant) => {
    setEditingTenant(t);
    setFormFullName(t.fullName);
    setFormPhone(t.phone);
    setFormEmail(t.email || '');
    setFormPropertyId(t.propertyId || '');
    setFormNotes(t.notes || '');
    setFormError(null);
    setIsModalOpen(true);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setFormError(null);

    if (!formFullName.trim()) {
      setFormError('El nombre completo del inquilino es obligatorio.');
      return;
    }
    if (!formPhone.trim() || formPhone.trim().length < 7) {
      setFormError('El número de teléfono es obligatorio (mínimo 7 caracteres).');
      return;
    }

    try {
      setIsSubmitting(true);
      const payload = {
        fullName: formFullName.trim(),
        phone: formPhone.trim(),
        email: formEmail.trim() || undefined,
        propertyId: formPropertyId ? formPropertyId : null,
        notes: formNotes.trim() || undefined,
        active: true,
      };

      if (editingTenant) {
        // If assigned property changed, sync both
        const oldPropId = editingTenant.propertyId;
        await onUpdateTenant(editingTenant.id, payload);

        if (oldPropId !== formPropertyId) {
          if (oldPropId) {
            await onAssignPropertyTenant(oldPropId, null);
          }
          if (formPropertyId) {
            await onAssignPropertyTenant(formPropertyId, editingTenant.id);
          }
        }
      } else {
        const newTenantId = await onCreateTenant(payload);
        if (formPropertyId && (newTenantId as any)) {
          await onAssignPropertyTenant(formPropertyId, newTenantId as any);
        }
      }

      setIsModalOpen(false);
    } catch (err: any) {
      setFormError(err.message || 'Error al guardar el inquilino.');
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleConfirmDeactivate = async () => {
    if (!deactivateTargetId) return;
    try {
      setIsSubmitting(true);
      const targetTenant = tenants.find((t) => t.id === deactivateTargetId);
      if (targetTenant?.propertyId) {
        await onAssignPropertyTenant(targetTenant.propertyId, null);
      }
      await onDeactivateTenant(deactivateTargetId);
      setDeactivateTargetId(null);
    } catch (err) {
      console.error('Error deactivating tenant:', err);
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-xl font-bold text-slate-900 tracking-tight sm:text-2xl">
            Gestión de Inquilinos
          </h2>
          <p className="text-sm text-slate-500 mt-1">
            Registro de arrendatarios, información de contacto y vinculación con propiedades.
          </p>
        </div>

        <button
          onClick={handleOpenCreateModal}
          className="flex items-center justify-center gap-2 rounded-lg bg-orange-600 px-4 py-2.5 text-xs font-semibold text-white shadow-2xs hover:bg-orange-700 transition-colors"
        >
          <Plus className="h-4 w-4" />
          Nuevo Inquilino
        </button>
      </div>

      {/* Search & Filter */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div className="relative flex-1 max-w-md">
          <Search className="pointer-events-none absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
          <input
            type="text"
            placeholder="Buscar por nombre, teléfono o email..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            className="w-full rounded-lg border border-slate-200 bg-white py-2 pl-9 pr-3 text-xs text-slate-800 placeholder-slate-400 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
          />
        </div>

        <label className="flex items-center gap-2 text-xs font-medium text-slate-600 cursor-pointer">
          <input
            type="checkbox"
            checked={showInactive}
            onChange={(e) => setShowInactive(e.target.checked)}
            className="rounded-sm border-slate-300 text-orange-600 focus:ring-orange-500"
          />
          Mostrar inactivos
        </label>
      </div>

      {/* Tenants Cards Grid */}
      {filteredTenants.length === 0 ? (
        <div className="rounded-xl border border-slate-200 bg-white p-12 text-center shadow-2xs">
          <Users className="mx-auto h-12 w-12 text-slate-300" />
          <h3 className="mt-3 text-sm font-bold text-slate-800">No hay inquilinos registrados</h3>
          <p className="mt-1 text-xs text-slate-500">
            {searchTerm ? 'No se encontraron resultados para tu búsqueda.' : 'Agrega inquilinos para asociarlos a tus propiedades en alquiler.'}
          </p>
          {!searchTerm && (
            <button
              onClick={handleOpenCreateModal}
              className="mt-4 inline-flex items-center gap-1.5 rounded-lg bg-orange-600 px-3.5 py-2 text-xs font-semibold text-white hover:bg-orange-700"
            >
              <Plus className="h-3.5 w-3.5" />
              Crear Inquilino
            </button>
          )}
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
          {filteredTenants.map((tenant) => {
            const assignedProp = tenant.propertyId ? propertyMap.get(tenant.propertyId) : null;

            return (
              <div
                key={tenant.id}
                className={`flex flex-col justify-between rounded-xl border bg-white p-5 shadow-2xs transition-all ${
                  tenant.active ? 'border-slate-200 hover:border-slate-300' : 'border-slate-200 bg-slate-50/60 opacity-80'
                }`}
              >
                <div>
                  <div className="flex items-start justify-between gap-2">
                    <div>
                      <h3 className="text-base font-bold text-slate-900 leading-snug">{tenant.fullName}</h3>
                      <div className="flex items-center gap-1.5 text-xs text-slate-600 mt-1">
                        <Phone className="h-3.5 w-3.5 text-slate-400 shrink-0" />
                        <a href={`tel:${tenant.phone}`} className="font-mono hover:text-orange-600">
                          {tenant.phone}
                        </a>
                      </div>
                    </div>
                    <span
                      className={`shrink-0 rounded-full px-2.5 py-0.5 text-[11px] font-semibold ${
                        tenant.active ? 'bg-emerald-100 text-emerald-800' : 'bg-slate-200 text-slate-700'
                      }`}
                    >
                      {tenant.active ? 'Activo' : 'Inactivo'}
                    </span>
                  </div>

                  {tenant.email && (
                    <div className="mt-2 flex items-center gap-1.5 text-xs text-slate-500">
                      <Mail className="h-3.5 w-3.5 text-slate-400 shrink-0" />
                      <span className="truncate">{tenant.email}</span>
                    </div>
                  )}

                  {/* Property Linkage */}
                  <div className="mt-4 rounded-lg bg-slate-50 p-2.5 text-xs">
                    <span className="text-[11px] font-medium text-slate-500 block mb-0.5">Propiedad asignada:</span>
                    {assignedProp ? (
                      <div className="flex items-center gap-1.5 font-semibold text-slate-900">
                        <Building2 className="h-3.5 w-3.5 text-orange-600 shrink-0" />
                        <span className="truncate">{assignedProp.name}</span>
                      </div>
                    ) : (
                      <span className="text-slate-400 italic">Sin propiedad asignada</span>
                    )}
                  </div>

                  {/* Notes */}
                  {tenant.notes && (
                    <div className="mt-3 text-xs text-slate-600 bg-amber-50/60 border border-amber-100/80 rounded-md p-2">
                      <span className="font-semibold text-amber-900 block text-[10px] uppercase">Notas:</span>
                      <p className="mt-0.5 line-clamp-2">{tenant.notes}</p>
                    </div>
                  )}
                </div>

                {/* Actions */}
                <div className="mt-5 flex items-center justify-end gap-2 border-t border-slate-100 pt-3">
                  <button
                    onClick={() => handleOpenEditModal(tenant)}
                    className="rounded-md p-1.5 text-slate-500 hover:bg-slate-100 hover:text-slate-800"
                    title="Editar inquilino"
                  >
                    <Edit2 className="h-3.5 w-3.5" />
                  </button>
                  {tenant.active && (
                    <button
                      onClick={() => setDeactivateTargetId(tenant.id)}
                      className="rounded-md p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                      title="Desactivar inquilino"
                    >
                      <UserMinus className="h-3.5 w-3.5" />
                    </button>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {/* Modal Crear / Editar Inquilino */}
      {isModalOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-900/40 backdrop-blur-xs">
          <div className="w-full max-w-md rounded-xl border border-slate-200 bg-white p-6 shadow-xl">
            <div className="flex items-center justify-between border-b border-slate-100 pb-3">
              <h3 className="text-base font-bold text-slate-900">
                {editingTenant ? 'Editar Inquilino' : 'Nuevo Inquilino'}
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
                  Nombre completo *
                </label>
                <input
                  type="text"
                  placeholder="Ej. Juan Carlos Pérez Rodríguez"
                  value={formFullName}
                  onChange={(e) => setFormFullName(e.target.value)}
                  required
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-700">
                  Teléfono / Móvil *
                </label>
                <input
                  type="tel"
                  placeholder="809-555-0199"
                  value={formPhone}
                  onChange={(e) => setFormPhone(e.target.value)}
                  required
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 font-mono focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                />
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-700">
                  Correo electrónico (opcional)
                </label>
                <input
                  type="email"
                  placeholder="inquilino@ejemplo.com"
                  value={formEmail}
                  onChange={(e) => setFormEmail(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                />
                <span className="text-[10px] text-slate-400">
                  En este MVP, las alertas automáticas de cobro se envían al propietario.
                </span>
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-700">
                  Asignar a Propiedad
                </label>
                <select
                  value={formPropertyId}
                  onChange={(e) => setFormPropertyId(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                >
                  <option value="">-- Sin asignar --</option>
                  {availableProperties.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name} ({p.address})
                    </option>
                  ))}
                </select>
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-700">
                  Notas adicionales (opcional)
                </label>
                <textarea
                  rows={2}
                  placeholder="Comentarios sobre el contrato, depósito, fiador..."
                  value={formNotes}
                  onChange={(e) => setFormNotes(e.target.value)}
                  className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
                />
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
                  {isSubmitting ? 'Guardando...' : editingTenant ? 'Actualizar Inquilino' : 'Crear Inquilino'}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Deactivate Modal */}
      <ConfirmModal
        isOpen={Boolean(deactivateTargetId)}
        title="Desactivar Inquilino"
        message="¿Estás seguro de que deseas desactivar este inquilino? Se desvinculará de su propiedad actual, pero se conservará todo su historial de pagos anteriores."
        confirmLabel="Desactivar Inquilino"
        isDestructive
        isLoading={isSubmitting}
        onConfirm={handleConfirmDeactivate}
        onCancel={() => setDeactivateTargetId(null)}
      />
    </div>
  );
};
