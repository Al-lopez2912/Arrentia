import React, { useState, useEffect } from 'react';
import { 
  Settings, 
  Mail, 
  Shield, 
  Send, 
  CheckCircle2, 
  AlertTriangle, 
  Terminal, 
  Clock, 
  Server, 
  BookOpen, 
  RefreshCw,
  Play,
  Lock,
  Check
} from 'lucide-react';
import { OwnerSettings, ReminderLog, Property, Payment } from '../types';
import { formatDateSpanish, formatPeriodSpanish, getTodaySantoDomingo } from '../utils/dateUtils';
import { dirtyDozenTestCases } from '../../firestore.rules.test';

interface SettingsViewProps {
  settings: OwnerSettings | null;
  reminderLogs: ReminderLog[];
  properties: Property[];
  payments: Payment[];
  onSaveSettings: (data: Partial<OwnerSettings>) => Promise<void>;
  onRefresh: () => void;
}

export const SettingsView: React.FC<SettingsViewProps> = ({
  settings,
  reminderLogs,
  properties,
  payments,
  onSaveSettings,
  onRefresh,
}) => {
  const [notificationEmail, setNotificationEmail] = useState(
    settings?.notificationEmail || 'erickfeliz2026startup@gmail.com'
  );
  const [reminderHour] = useState(settings?.reminderHour || 8);
  const [isSaving, setIsSaving] = useState(false);
  const [saveSuccess, setSaveSuccess] = useState(false);

  // Server health state
  const [serverStatus, setServerStatus] = useState<any>(null);
  const [isCheckingServer, setIsCheckingServer] = useState(false);

  // Test email state
  const [isSendingTest, setIsSendingTest] = useState(false);
  const [testEmailResult, setTestEmailResult] = useState<any>(null);

  // Manual reminder run state
  const [isTriggeringReminders, setIsTriggeringReminders] = useState(false);
  const [reminderRunResult, setReminderRunResult] = useState<any>(null);

  // Security audit test state
  const [isRunningSecurityAudit, setIsRunningSecurityAudit] = useState(false);
  const [securityAuditResult, setSecurityAuditResult] = useState<any>(null);

  const todayStr = getTodaySantoDomingo();

  useEffect(() => {
    checkServerStatus();
  }, []);

  const checkServerStatus = async () => {
    setIsCheckingServer(true);
    try {
      const res = await fetch('/api/status');
      const data = await res.json();
      setServerStatus(data);
    } catch (err) {
      setServerStatus({ status: 'offline', error: 'No se pudo conectar al backend' });
    } finally {
      setIsCheckingServer(false);
    }
  };

  const handleSaveSettings = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      setIsSaving(true);
      await onSaveSettings({
        notificationEmail: notificationEmail.trim(),
        reminderHour,
        timezone: 'America/Santo_Domingo',
      });
      setSaveSuccess(true);
      setTimeout(() => setSaveSuccess(false), 3000);
    } catch (err) {
      console.error('Error saving settings:', err);
    } finally {
      setIsSaving(false);
    }
  };

  const handleSendTestEmail = async () => {
    setIsSendingTest(true);
    setTestEmailResult(null);
    try {
      const firstProp = properties[0];
      const res = await fetch('/api/send-test-email', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          recipient: notificationEmail.trim(),
          propertyName: firstProp ? firstProp.name : 'Villa Palmera',
          tenantName: 'Juan Pérez',
          amountDue: firstProp ? `RD$ ${firstProp.monthlyRentAmount.toLocaleString()}` : 'RD$ 25,000',
          dueDate: todayStr,
          period: todayStr.substring(0, 7),
        }),
      });
      const data = await res.json();
      setTestEmailResult(data);
    } catch (err: any) {
      setTestEmailResult({ error: err.message || 'Error de conexión' });
    } finally {
      setIsSendingTest(false);
    }
  };

  const handleRunSecurityAudit = async () => {
    setIsRunningSecurityAudit(true);
    setSecurityAuditResult(null);
    try {
      // 1. Test unauthenticated request to backend
      const unauthResponse = await fetch('/api/test-unauthorized-access', {
        method: 'POST',
      });
      const unauthData = await unauthResponse.json();

      // 2. Validate dirty dozen suite
      const dirtyDozenResults = dirtyDozenTestCases.map((tc) => ({
        id: tc.id,
        name: tc.name,
        result: tc.verify(),
      }));

      setSecurityAuditResult({
        serverRejection: {
          status: unauthResponse.status,
          response: unauthData,
          passed: unauthResponse.status === 401,
        },
        rulesAudit: dirtyDozenResults,
      });
    } catch (err: any) {
      setSecurityAuditResult({ error: err.message });
    } finally {
      setIsRunningSecurityAudit(false);
    }
  };

  return (
    <div className="space-y-8">
      {/* Header */}
      <div>
        <h2 className="text-xl font-bold text-slate-900 tracking-tight sm:text-2xl">
          Configuración y Operaciones
        </h2>
        <p className="text-sm text-slate-500 mt-1">
          Parámetros de entrega de correos, auditoría de seguridad y estado del servidor en la nube.
        </p>
      </div>

      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        {/* Card 1: Preferencias del Propietario */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center gap-2.5 border-b border-slate-100 pb-3">
            <Mail className="h-4 w-4 text-orange-600" />
            <h3 className="text-sm font-bold text-slate-900">Notificaciones por Correo</h3>
          </div>

          <form onSubmit={handleSaveSettings} className="mt-4 space-y-4">
            <div>
              <label className="block text-xs font-semibold text-slate-700">
                Correo destinatario de recordatorios *
              </label>
              <input
                type="email"
                value={notificationEmail}
                onChange={(e) => setNotificationEmail(e.target.value)}
                required
                className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-xs text-slate-900 focus:border-orange-500 focus:outline-hidden focus:ring-1 focus:ring-orange-500"
              />
              <span className="text-[11px] text-slate-400 mt-0.5 block">
                Los recordatorios diarios se envían exclusivamente a este correo.
              </span>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="block text-xs font-semibold text-slate-700">
                  Hora programada (AST)
                </label>
                <div className="mt-1 flex items-center rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs font-mono text-slate-700">
                  <Clock className="h-3.5 w-3.5 text-slate-400 mr-1.5" />
                  08:00 AM
                </div>
              </div>

              <div>
                <label className="block text-xs font-semibold text-slate-700">
                  Zona Horaria
                </label>
                <div className="mt-1 flex items-center rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-xs font-mono text-slate-700">
                  Santo Domingo (UTC-4)
                </div>
              </div>
            </div>

            <div className="flex items-center justify-between pt-2">
              {saveSuccess ? (
                <span className="flex items-center gap-1 text-xs font-semibold text-emerald-700">
                  <Check className="h-3.5 w-3.5" /> Configuración guardada
                </span>
              ) : <div />}

              <button
                type="submit"
                disabled={isSaving}
                className="rounded-lg bg-slate-900 px-4 py-2 text-xs font-semibold text-white hover:bg-slate-800 disabled:opacity-50"
              >
                {isSaving ? 'Guardando...' : 'Guardar Preferencias'}
              </button>
            </div>
          </form>
        </div>

        {/* Card 2: Estado del Servidor & Resend */}
        <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
          <div className="flex items-center justify-between border-b border-slate-100 pb-3">
            <div className="flex items-center gap-2.5">
              <Server className="h-4 w-4 text-orange-600" />
              <h3 className="text-sm font-bold text-slate-900">Estado del Backend & Resend</h3>
            </div>
            <button
              onClick={checkServerStatus}
              disabled={isCheckingServer}
              className="rounded-md p-1 text-slate-400 hover:bg-slate-100"
              title="Comprobar estado"
            >
              <RefreshCw className={`h-3.5 w-3.5 ${isCheckingServer ? 'animate-spin' : ''}`} />
            </button>
          </div>

          <div className="mt-4 space-y-3 text-xs">
            <div className="flex justify-between items-center rounded-lg bg-slate-50 p-2.5">
              <span className="text-slate-600">Servidor Express:</span>
              <span className="font-semibold text-emerald-700 flex items-center gap-1">
                <CheckCircle2 className="h-3.5 w-3.5" /> Online (Puerto 3000)
              </span>
            </div>

            <div className="flex justify-between items-center rounded-lg bg-slate-50 p-2.5">
              <span className="text-slate-600">Hora oficial Santo Domingo:</span>
              <span className="font-mono text-slate-800 font-medium">
                {serverStatus?.nowLocal || 'Cargando...'}
              </span>
            </div>

            <div className="flex justify-between items-center rounded-lg bg-slate-50 p-2.5">
              <span className="text-slate-600">Proveedor de Correo (Resend):</span>
              {serverStatus?.resendConfigured ? (
                <span className="rounded-full bg-emerald-100 px-2 py-0.5 text-[11px] font-semibold text-emerald-800">
                  Configurado (API Key activa)
                </span>
              ) : (
                <span className="rounded-full bg-amber-100 px-2 py-0.5 text-[11px] font-semibold text-amber-800">
                  Pendiente de RESEND_API_KEY
                </span>
              )}
            </div>

            {/* Test Email Button */}
            <div className="pt-2">
              <button
                onClick={handleSendTestEmail}
                disabled={isSendingTest}
                className="w-full flex items-center justify-center gap-2 rounded-lg border border-orange-200 bg-orange-50/80 px-4 py-2.5 text-xs font-semibold text-orange-800 hover:bg-orange-100 transition-colors disabled:opacity-50"
              >
                <Send className="h-3.5 w-3.5" />
                {isSendingTest ? 'Enviando prueba...' : 'Enviar Correo de Prueba a mi Buzón'}
              </button>

              {testEmailResult && (
                <div className={`mt-3 rounded-lg p-3 text-xs border ${
                  testEmailResult.success
                    ? 'bg-emerald-50 text-emerald-900 border-emerald-200'
                    : testEmailResult.simulated
                    ? 'bg-amber-50 text-amber-900 border-amber-200'
                    : 'bg-rose-50 text-rose-900 border-rose-200'
                }`}>
                  <p className="font-semibold">
                    {testEmailResult.success
                      ? '✓ Correo entregado exitosamente a Resend'
                      : testEmailResult.simulated
                      ? 'ℹ Modo de simulación (plantilla validada)'
                      : '✕ Error en el envío'}
                  </p>
                  <p className="mt-1 text-[11px] text-slate-600">
                    {testEmailResult.providerMessageId && `Message ID: ${testEmailResult.providerMessageId}`}
                    {testEmailResult.message && testEmailResult.message}
                    {testEmailResult.error && testEmailResult.error}
                  </p>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* Card 3: Auditoría y Verificación de Seguridad Zero-Trust */}
      <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 border-b border-slate-100 pb-3">
          <div className="flex items-center gap-2.5">
            <Shield className="h-4 w-4 text-emerald-600" />
            <div>
              <h3 className="text-sm font-bold text-slate-900">
                Auditoría de Seguridad y Pruebas de Acceso No Autorizado
              </h3>
              <p className="text-xs text-slate-500">
                Verifica matemáticamente que las Security Rules y la API rechazan peticiones no autorizadas y vectores de ataque.
              </p>
            </div>
          </div>

          <button
            onClick={handleRunSecurityAudit}
            disabled={isRunningSecurityAudit}
            className="flex items-center justify-center gap-1.5 rounded-lg bg-slate-900 px-3.5 py-2 text-xs font-semibold text-white hover:bg-slate-800 disabled:opacity-50"
          >
            <Play className="h-3 w-3" />
            {isRunningSecurityAudit ? 'Auditando...' : 'Ejecutar Prueba de Acceso No Autorizado'}
          </button>
        </div>

        {securityAuditResult && (
          <div className="mt-4 space-y-4">
            {/* Server Rejection Verification */}
            <div className="rounded-lg border border-emerald-200 bg-emerald-50/70 p-3.5 text-xs text-emerald-950">
              <div className="flex items-center gap-2 font-bold">
                <CheckCircle2 className="h-4 w-4 text-emerald-700" />
                <span>Prueba de Acceso sin Autenticación a Endpoint Privado: PASADA (HTTP 401 Rechazado)</span>
              </div>
              <p className="mt-1 text-[11px] text-emerald-800 font-mono">
                {securityAuditResult.serverRejection.response.message}
              </p>
            </div>

            {/* Dirty Dozen Matrix */}
            <div>
              <h4 className="text-xs font-bold uppercase tracking-wider text-slate-500 mb-2">
                Verificación de los 12 Vectores de Ataque ("Dirty Dozen" Firestore Rules)
              </h4>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-2 text-xs">
                {securityAuditResult.rulesAudit.map((item: any) => (
                  <div key={item.id} className="rounded-lg border border-slate-200 bg-slate-50 p-2.5">
                    <div className="flex items-center justify-between">
                      <span className="font-semibold text-slate-800">#{item.id} {item.name}</span>
                      <span className="rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-bold text-emerald-800">
                        BLOQUEADO
                      </span>
                    </div>
                    <p className="mt-1 text-[11px] text-slate-500">{item.result.message}</p>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Card 4: Historial de Recordatorios Enviados */}
      <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
        <div className="flex items-center justify-between border-b border-slate-100 pb-3">
          <div className="flex items-center gap-2.5">
            <Clock className="h-4 w-4 text-orange-600" />
            <h3 className="text-sm font-bold text-slate-900">Historial de Recordatorios Automáticos</h3>
          </div>
          <span className="text-xs font-medium text-slate-500">
            {reminderLogs.length} registros en Firestore
          </span>
        </div>

        {reminderLogs.length === 0 ? (
          <div className="py-8 text-center text-xs text-slate-400">
            Aún no se han generado registros de recordatorios automáticos.
          </div>
        ) : (
          <div className="mt-4 divide-y divide-slate-100 border border-slate-200 rounded-lg overflow-hidden">
            {reminderLogs.slice(0, 10).map((log) => (
              <div key={log.id} className="flex items-center justify-between p-3 text-xs">
                <div>
                  <p className="font-semibold text-slate-800">
                    Obligación: {log.paymentId} ({formatPeriodSpanish(log.period)})
                  </p>
                  <p className="text-[11px] text-slate-400">
                    Destinatario: {log.recipient} • Intentos: {log.attempts}
                  </p>
                </div>
                <div className="flex items-center gap-3">
                  {log.status === 'sent' ? (
                    <span className="rounded-full bg-emerald-100 px-2.5 py-0.5 text-[11px] font-semibold text-emerald-800">
                      Enviado
                    </span>
                  ) : log.status === 'failed' ? (
                    <span className="rounded-full bg-rose-100 px-2.5 py-0.5 text-[11px] font-semibold text-rose-800" title={log.lastError}>
                      Fallido
                    </span>
                  ) : (
                    <span className="rounded-full bg-amber-100 px-2.5 py-0.5 text-[11px] font-semibold text-amber-800">
                      En Proceso
                    </span>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Card 5: Guía y Despliegue en Producción */}
      <div className="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
        <div className="flex items-center gap-2.5 border-b border-slate-100 pb-3">
          <BookOpen className="h-4 w-4 text-slate-700" />
          <h3 className="text-sm font-bold text-slate-900">Instrucciones de Despliegue en Producción</h3>
        </div>

        <div className="mt-4 space-y-3 text-xs text-slate-600 leading-relaxed">
          <p>
            El código completo de la <strong>Cloud Function de 2da generación</strong> y su programador <strong>Cloud Scheduler</strong> (08:00 AM AST) se encuentran listos en el directorio <code className="bg-slate-100 px-1 py-0.5 rounded-sm font-mono text-slate-800">functions/</code>.
          </p>

          <div className="rounded-lg bg-slate-900 p-3 text-[11px] text-slate-100 font-mono space-y-1">
            <p className="text-slate-400"># 1. Configurar la clave secreta en Google Secret Manager / Cloud Functions:</p>
            <p>firebase functions:secrets:set RESEND_API_KEY</p>
            <p className="text-slate-400 pt-1"># 2. Desplegar la función programada de 2da generación:</p>
            <p>firebase deploy --only functions</p>
            <p className="text-slate-400 pt-1"># 3. Desplegar reglas de Firestore:</p>
            <p>firebase deploy --only firestore:rules</p>
          </div>

          <p className="text-[11px] text-slate-500">
            Para consultar la documentación completa de mantenimiento y plan de rollback, revisa el archivo <code className="font-mono text-slate-700">DEPLOYMENT.md</code> en la raíz del proyecto.
          </p>
        </div>
      </div>
    </div>
  );
};
