/**
 * @license
 * SPDX-License-Identifier: Apache-2.0
 */

import React, { useState, useEffect, useCallback } from 'react';
import { AuthProvider, useAuth } from './context/AuthContext';
import { testConnection } from './firebase';
import { LoginView } from './views/LoginView';
import { Sidebar } from './components/Sidebar';
import { Header } from './components/Header';
import { DashboardView } from './views/DashboardView';
import { PropertiesView } from './views/PropertiesView';
import { TenantsView } from './views/TenantsView';
import { PaymentsView } from './views/PaymentsView';
import { SettingsView } from './views/SettingsView';
import { Property, Tenant, Payment, ReminderLog, OwnerSettings } from './types';
import {
  fetchProperties,
  createProperty,
  updateProperty,
  archiveProperty,
  fetchTenants,
  createTenant,
  updateTenant,
  deactivateTenant,
  fetchPayments,
  ensureMonthlyPayments,
  markPaymentAsPaid,
  fetchReminderLogs,
  fetchOwnerSettings,
  saveOwnerSettings,
} from './services/dataService';
import { getCurrentPeriodSantoDomingo } from './utils/dateUtils';
import { AlertTriangle, CheckCircle2, X } from 'lucide-react';

function MainApp() {
  const { user, isOwner, loading: authLoading } = useAuth();
  const [currentTab, setCurrentTab] = useState<string>('inicio');
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);

  // Data states
  const [properties, setProperties] = useState<Property[]>([]);
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [payments, setPayments] = useState<Payment[]>([]);
  const [reminderLogs, setReminderLogs] = useState<ReminderLog[]>([]);
  const [settings, setSettings] = useState<OwnerSettings | null>(null);
  const [loadingData, setLoadingData] = useState(false);
  const [isGeneratingPayments, setIsGeneratingPayments] = useState(false);

  // Toast notifications
  const [toast, setToast] = useState<{ type: 'success' | 'error'; message: string } | null>(null);

  const showToast = (type: 'success' | 'error', message: string) => {
    setToast({ type, message });
    setTimeout(() => setToast(null), 4000);
  };

  // Connection validation on boot
  useEffect(() => {
    testConnection();
  }, []);

  const loadAllData = useCallback(async () => {
    if (!user || !isOwner) return;

    try {
      setLoadingData(true);
      const [propsData, tenantsData, paymentsData, logsData, settingsData] = await Promise.all([
        fetchProperties(user.uid),
        fetchTenants(user.uid),
        fetchPayments(user.uid),
        fetchReminderLogs(user.uid),
        fetchOwnerSettings(user.uid),
      ]);

      setProperties(propsData);
      setTenants(tenantsData);
      setPayments(paymentsData);
      setReminderLogs(logsData);
      setSettings(settingsData);
    } catch (err: any) {
      console.error('Error cargando datos de Firestore:', err);
      showToast('error', 'Error al sincronizar datos con Firestore.');
    } finally {
      setLoadingData(false);
    }
  }, [user, isOwner]);

  useEffect(() => {
    if (user && isOwner) {
      loadAllData();
    }
  }, [user, isOwner, loadAllData]);

  // Handler: Ensure monthly payments
  const handleEnsurePayments = async (period: string = getCurrentPeriodSantoDomingo()) => {
    if (!user) return;
    try {
      setIsGeneratingPayments(true);
      const createdCount = await ensureMonthlyPayments(user.uid, properties, period);
      await loadAllData();
      if (createdCount > 0) {
        showToast('success', `Se generaron ${createdCount} nuevas obligaciones para el período ${period}.`);
      } else {
        showToast('success', `Todas las obligaciones para ${period} ya están generadas y al día.`);
      }
    } catch (err: any) {
      console.error('Error generando pagos:', err);
      showToast('error', 'No se pudieron generar los pagos del mes.');
    } finally {
      setIsGeneratingPayments(false);
    }
  };

  // Handler: Property operations
  const handleCreateProperty = async (data: Omit<Property, 'id' | 'ownerUid' | 'createdAt' | 'updatedAt'>) => {
    if (!user) return;
    try {
      await createProperty(user.uid, data);
      await loadAllData();
      showToast('success', 'Propiedad registrada exitosamente.');
    } catch (err: any) {
      console.error('Error creando propiedad:', err);
      showToast('error', 'Error al guardar la propiedad.');
      throw err;
    }
  };

  const handleUpdateProperty = async (id: string, data: Partial<Property>) => {
    try {
      await updateProperty(id, data);
      await loadAllData();
      showToast('success', 'Propiedad actualizada.');
    } catch (err: any) {
      console.error('Error actualizando propiedad:', err);
      showToast('error', 'Error al actualizar propiedad.');
      throw err;
    }
  };

  const handleArchiveProperty = async (id: string) => {
    try {
      await archiveProperty(id);
      await loadAllData();
      showToast('success', 'Propiedad archivada.');
    } catch (err: any) {
      console.error('Error archivando propiedad:', err);
      showToast('error', 'Error al archivar propiedad.');
      throw err;
    }
  };

  // Handler: Tenant operations
  const handleCreateTenant = async (data: Omit<Tenant, 'id' | 'ownerUid' | 'createdAt' | 'updatedAt'>) => {
    if (!user) return;
    try {
      const newId = await createTenant(user.uid, data);
      await loadAllData();
      showToast('success', 'Inquilino registrado exitosamente.');
      return newId as any;
    } catch (err: any) {
      console.error('Error creando inquilino:', err);
      showToast('error', 'Error al crear inquilino.');
      throw err;
    }
  };

  const handleUpdateTenant = async (id: string, data: Partial<Tenant>) => {
    try {
      await updateTenant(id, data);
      await loadAllData();
      showToast('success', 'Inquilino actualizado.');
    } catch (err: any) {
      console.error('Error actualizando inquilino:', err);
      showToast('error', 'Error al actualizar inquilino.');
      throw err;
    }
  };

  const handleDeactivateTenant = async (id: string) => {
    try {
      await deactivateTenant(id);
      await loadAllData();
      showToast('success', 'Inquilino desactivado.');
    } catch (err: any) {
      console.error('Error desactivando inquilino:', err);
      showToast('error', 'Error al desactivar inquilino.');
      throw err;
    }
  };

  const handleAssignPropertyTenant = async (propertyId: string, tenantId: string | null) => {
    try {
      await updateProperty(propertyId, { tenantId });
      await loadAllData();
    } catch (err) {
      console.error('Error asignando inquilino:', err);
    }
  };

  // Handler: Mark Payment as Paid
  const handleMarkPaymentAsPaid = async (payment: Payment) => {
    try {
      await markPaymentAsPaid(payment);
      await loadAllData();
      showToast('success', 'Cobro registrado y marcado como Pagado con marca de tiempo del servidor.');
    } catch (err: any) {
      console.error('Error marcando pago como pagado:', err);
      showToast('error', 'Error al registrar el cobro.');
      throw err;
    }
  };

  // Handler: Save Settings
  const handleSaveSettings = async (data: Partial<OwnerSettings>) => {
    if (!user) return;
    try {
      await saveOwnerSettings(user.uid, data);
      await loadAllData();
      showToast('success', 'Configuraciones guardadas.');
    } catch (err: any) {
      console.error('Error guardando configuraciones:', err);
      showToast('error', 'Error al guardar configuraciones.');
      throw err;
    }
  };

  if (authLoading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-slate-50">
        <div className="flex flex-col items-center gap-3">
          <div className="h-8 w-8 animate-spin rounded-full border-4 border-orange-600 border-t-transparent" />
          <p className="text-xs font-semibold text-slate-500">Cargando Control de Alquileres...</p>
        </div>
      </div>
    );
  }

  if (!user || !isOwner) {
    return <LoginView />;
  }

  return (
    <div className="flex min-h-screen bg-[#F8FAFC]">
      {/* Toast message */}
      {toast && (
        <div
          className={`fixed top-4 right-4 z-50 flex items-center gap-2 rounded-xl px-4 py-3 text-xs font-semibold shadow-lg transition-all animate-in slide-in-from-top-2 ${
            toast.type === 'success'
              ? 'bg-emerald-800 text-white'
              : 'bg-rose-800 text-white'
          }`}
        >
          {toast.type === 'success' ? (
            <CheckCircle2 className="h-4 w-4 shrink-0 text-emerald-300" />
          ) : (
            <AlertTriangle className="h-4 w-4 shrink-0 text-rose-300" />
          )}
          <span>{toast.message}</span>
          <button
            onClick={() => setToast(null)}
            className="ml-2 rounded-md p-1 hover:bg-white/20"
          >
            <X className="h-3.5 w-3.5" />
          </button>
        </div>
      )}

      {/* Desktop and Mobile Sidebar */}
      <Sidebar
        currentTab={currentTab}
        onSelectTab={setCurrentTab}
        mobileOpen={mobileMenuOpen}
        onCloseMobile={() => setMobileMenuOpen(false)}
      />

      {/* Main Content Area */}
      <div className="flex flex-1 flex-col overflow-hidden">
        <Header
          title={currentTab}
          onOpenMobileMenu={() => setMobileMenuOpen(true)}
        />

        <main className="flex-1 overflow-y-auto p-4 sm:p-6 lg:p-8">
          <div className="mx-auto max-w-6xl">
            {currentTab === 'inicio' && (
              <DashboardView
                properties={properties}
                tenants={tenants}
                payments={payments}
                onNavigate={setCurrentTab}
                onRefresh={loadAllData}
                onEnsurePayments={() => handleEnsurePayments()}
                isGenerating={isGeneratingPayments}
              />
            )}

            {currentTab === 'propiedades' && (
              <PropertiesView
                properties={properties}
                tenants={tenants}
                payments={payments}
                onCreateProperty={handleCreateProperty}
                onUpdateProperty={handleUpdateProperty}
                onArchiveProperty={handleArchiveProperty}
              />
            )}

            {currentTab === 'inquilinos' && (
              <TenantsView
                tenants={tenants}
                properties={properties}
                onCreateTenant={handleCreateTenant}
                onUpdateTenant={handleUpdateTenant}
                onDeactivateTenant={handleDeactivateTenant}
                onAssignPropertyTenant={handleAssignPropertyTenant}
              />
            )}

            {currentTab === 'pagos' && (
              <PaymentsView
                payments={payments}
                properties={properties}
                tenants={tenants}
                onMarkAsPaid={handleMarkPaymentAsPaid}
                onEnsurePayments={handleEnsurePayments}
                onRefresh={loadAllData}
                isGenerating={isGeneratingPayments}
              />
            )}

            {currentTab === 'configuracion' && (
              <SettingsView
                settings={settings}
                reminderLogs={reminderLogs}
                properties={properties}
                payments={payments}
                onSaveSettings={handleSaveSettings}
                onRefresh={loadAllData}
              />
            )}
          </div>
        </main>
      </div>
    </div>
  );
}

export default function App() {
  return (
    <AuthProvider>
      <MainApp />
    </AuthProvider>
  );
}
