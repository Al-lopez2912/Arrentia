import { onSchedule } from 'firebase-functions/v2/scheduler';
import { onRequest } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';
import { Resend } from 'resend';

if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

const SANTO_DOMINGO_TZ = 'America/Santo_Domingo';

/**
 * Returns today formatted as YYYY-MM-DD in America/Santo_Domingo timezone
 */
function getTodaySantoDomingo(): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: SANTO_DOMINGO_TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

/**
 * Clamps due date to month length
 */
function calculateDueDate(period: string, dueDay: number): string {
  const [yearStr, monthStr] = period.split('-');
  const year = parseInt(yearStr, 10);
  const month = parseInt(monthStr, 10);
  const lastDayOfMonth = new Date(year, month, 0).getDate();
  const clampedDay = Math.min(Math.max(dueDay, 1), lastDayOfMonth);
  return `${year}-${String(month).padStart(2, '0')}-${String(clampedDay).padStart(2, '0')}`;
}

/**
 * Formats monetary amounts in Dominican Pesos
 */
function formatCurrencyDOP(amount: number): string {
  return new Intl.NumberFormat('es-DO', {
    style: 'currency',
    currency: 'DOP',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  }).format(amount);
}

/**
 * Core Reminder Processing Routine
 */
export async function executeReminderProcess(resendApiKey?: string) {
  const today = getTodaySantoDomingo();
  const period = today.substring(0, 7);
  const apiKey = resendApiKey || process.env.RESEND_API_KEY;

  const results = {
    date: today,
    period,
    paymentsCreated: 0,
    remindersProcessed: 0,
    remindersSent: 0,
    remindersSkipped: 0,
    errors: [] as string[],
  };

  // 1. Fetch active properties
  const propertiesSnap = await db.collection('properties').where('active', '==', true).get();
  if (propertiesSnap.empty) {
    return results;
  }

  // 2. Map properties and tenants
  const tenantsSnap = await db.collection('tenants').get();
  const tenantMap = new Map<string, any>();
  tenantsSnap.forEach((doc) => tenantMap.set(doc.id, doc.data()));

  // 3. For each active property, ensure monthly payment record exists idempotently
  for (const propDoc of propertiesSnap.docs) {
    const prop = propDoc.data();
    const propId = propDoc.id;

    // Check lease validity
    if (prop.leaseStartDate && prop.leaseStartDate > today) continue;
    if (prop.leaseEndDate && prop.leaseEndDate < today) continue;

    const paymentId = `${propId}_${period}`;
    const paymentRef = db.collection('payments').doc(paymentId);
    const paymentDoc = await paymentRef.get();

    let paymentData: any;
    if (!paymentDoc.exists) {
      const dueDate = calculateDueDate(period, prop.dueDay || 1);
      paymentData = {
        ownerUid: prop.ownerUid,
        propertyId: propId,
        tenantId: prop.tenantId || null,
        period,
        amountDue: Math.round(prop.monthlyRentAmount || 0),
        dueDate,
        status: 'pending',
        paidAt: null,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      };
      await paymentRef.set(paymentData);
      results.paymentsCreated++;
    } else {
      paymentData = paymentDoc.data();
    }

    // 4. Check if payment is due TODAY and status is still PENDING
    if (paymentData.dueDate === today && paymentData.status === 'pending') {
      results.remindersProcessed++;

      // 5. Query owner settings for notification email
      const settingsDoc = await db.collection('settings').doc(prop.ownerUid).get();
      const ownerEmail = settingsDoc.exists
        ? settingsDoc.data()?.notificationEmail
        : 'erickfeliz2026startup@gmail.com';

      const reminderRef = db.collection('reminderLogs').doc(paymentId);

      // 6. Use transaction for atomic reservation to prevent concurrent duplicate sends
      const canProceed = await db.runTransaction(async (t) => {
        const logDoc = await t.get(reminderRef);
        if (logDoc.exists) {
          const log = logDoc.data();
          if (log?.status === 'sent') {
            return false; // Already successfully sent
          }
          if (log?.status === 'processing') {
            // Check if stuck for more than 10 minutes
            const updatedAt = new Date(log.updatedAt || 0).getTime();
            if (Date.now() - updatedAt < 10 * 60 * 1000) {
              return false; // In-flight
            }
          }
        }

        t.set(
          reminderRef,
          {
            ownerUid: prop.ownerUid,
            paymentId,
            propertyId: propId,
            period,
            recipient: ownerEmail,
            scheduledFor: today,
            status: 'processing',
            attempts: admin.firestore.FieldValue.increment(1),
            updatedAt: new Date().toISOString(),
            createdAt: new Date().toISOString(),
          },
          { merge: true }
        );
        return true;
      });

      if (!canProceed) {
        results.remindersSkipped++;
        continue;
      }

      // 7. Dispatch Email via Resend
      const tenant = prop.tenantId ? tenantMap.get(prop.tenantId) : null;
      const tenantName = tenant?.fullName || 'No asignado';
      const formattedAmount = formatCurrencyDOP(paymentData.amountDue);

      const subject = `Recordatorio de alquiler pendiente — ${prop.name}`;
      const emailBodyText = `Hola,\n\nHoy corresponde el pago del alquiler de la siguiente propiedad:\n\nPropiedad: ${prop.name}\nInquilino: ${tenantName}\nImporte: ${formattedAmount}\nFecha de vencimiento: ${paymentData.dueDate}\nPeríodo: ${period}\n\nEstado actual: Pendiente de pago.\n\nPor favor, verifica si has recibido el pago y actualiza el estado en Control de Alquileres.\n\nEste mensaje es una notificación automática.`;

      if (!apiKey) {
        await reminderRef.update({
          status: 'failed',
          lastError: 'RESEND_API_KEY not configured on server.',
          updatedAt: new Date().toISOString(),
        });
        results.errors.push(`API key missing for payment ${paymentId}`);
        continue;
      }

      try {
        const resend = new Resend(apiKey);
        const { data: resendData, error: sendError } = await resend.emails.send({
          from: 'Control de Alquileres <notificaciones@resend.dev>',
          to: [ownerEmail],
          subject,
          text: emailBodyText,
        });

        if (sendError) {
          await reminderRef.update({
            status: 'failed',
            lastError: sendError.message || 'Error sending email',
            updatedAt: new Date().toISOString(),
          });
          results.errors.push(`Send failed: ${sendError.message}`);
        } else {
          await reminderRef.update({
            status: 'sent',
            providerMessageId: resendData?.id || 'resend-ok',
            lastError: null,
            updatedAt: new Date().toISOString(),
          });
          results.remindersSent++;
        }
      } catch (err: any) {
        await reminderRef.update({
          status: 'failed',
          lastError: err?.message || 'Unexpected exception',
          updatedAt: new Date().toISOString(),
        });
        results.errors.push(`Exception: ${err?.message}`);
      }
    }
  }

  return results;
}

/**
 * 2nd Generation Cloud Function with Cloud Scheduler
 * Runs daily at 8:00 AM America/Santo_Domingo
 */
export const scheduledDailyRentalReminder = onSchedule(
  {
    schedule: '0 8 * * *',
    timeZone: SANTO_DOMINGO_TZ,
    secrets: ['RESEND_API_KEY'],
    retryCount: 2,
    memory: '256MiB',
  },
  async () => {
    console.log('[Cloud Scheduler] Starting daily rental reminder processing at 8:00 AM AST...');
    const result = await executeReminderProcess();
    console.log('[Cloud Scheduler] Finished execution:', JSON.stringify(result));
  }
);

/**
 * HTTPS endpoint to trigger or verify reminder execution manually with authentication
 */
export const manualRentalReminderTrigger = onRequest(
  {
    secrets: ['RESEND_API_KEY'],
    cors: true,
  },
  async (req, res) => {
    const authHeader = req.headers.authorization;
    if (!authHeader?.startsWith('Bearer ')) {
      res.status(401).json({ error: 'Unauthorized: Missing bearer token' });
      return;
    }

    try {
      const idToken = authHeader.split('Bearer ')[1];
      const decoded = await admin.auth().verifyIdToken(idToken);
      if (decoded.email !== 'erickfeliz2026startup@gmail.com') {
        res.status(403).json({ error: 'Forbidden: Owner access required' });
        return;
      }

      const result = await executeReminderProcess();
      res.json({ success: true, result });
    } catch (error: any) {
      res.status(500).json({ error: error.message });
    }
  }
);
