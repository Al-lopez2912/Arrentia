import {
  collection,
  doc,
  getDocs,
  getDoc,
  setDoc,
  updateDoc,
  query,
  where,
  serverTimestamp,
} from 'firebase/firestore';
import { db, handleFirestoreError } from '../firebase';
import { Property, Tenant, Payment, ReminderLog, OwnerSettings, OperationType } from '../types';
import { calculateDueDate, getCurrentPeriodSantoDomingo, getTodaySantoDomingo } from '../utils/dateUtils';

// ========================
// PROPERTIES
// ========================

export async function fetchProperties(ownerUid: string): Promise<Property[]> {
  const colPath = 'properties';
  try {
    const q = query(collection(db, colPath), where('ownerUid', '==', ownerUid));
    const snap = await getDocs(q);
    return snap.docs.map((d) => ({ id: d.id, ...(d.data() as Omit<Property, 'id'>) }));
  } catch (err) {
    handleFirestoreError(err, OperationType.LIST, colPath);
  }
}

export async function createProperty(
  ownerUid: string,
  data: Omit<Property, 'id' | 'ownerUid' | 'createdAt' | 'updatedAt'>
): Promise<string> {
  const colPath = 'properties';
  try {
    const newDocRef = doc(collection(db, colPath));
    const now = new Date().toISOString();
    const payload: Omit<Property, 'id'> = {
      ...data,
      ownerUid,
      monthlyRentAmount: Math.round(data.monthlyRentAmount),
      dueDay: Math.min(Math.max(data.dueDay, 1), 31),
      createdAt: now,
      updatedAt: now,
    };
    await setDoc(newDocRef, payload);
    return newDocRef.id;
  } catch (err) {
    handleFirestoreError(err, OperationType.CREATE, colPath);
  }
}

export async function updateProperty(
  propertyId: string,
  data: Partial<Property>
): Promise<void> {
  const docPath = `properties/${propertyId}`;
  try {
    const docRef = doc(db, 'properties', propertyId);
    const updatePayload: Record<string, any> = {
      ...data,
      updatedAt: new Date().toISOString(),
    };
    if (data.monthlyRentAmount !== undefined) {
      updatePayload.monthlyRentAmount = Math.round(data.monthlyRentAmount);
    }
    if (data.dueDay !== undefined) {
      updatePayload.dueDay = Math.min(Math.max(data.dueDay, 1), 31);
    }
    await updateDoc(docRef, updatePayload);
  } catch (err) {
    handleFirestoreError(err, OperationType.UPDATE, docPath);
  }
}

export async function archiveProperty(propertyId: string): Promise<void> {
  return updateProperty(propertyId, { active: false });
}

// ========================
// TENANTS
// ========================

export async function fetchTenants(ownerUid: string): Promise<Tenant[]> {
  const colPath = 'tenants';
  try {
    const q = query(collection(db, colPath), where('ownerUid', '==', ownerUid));
    const snap = await getDocs(q);
    return snap.docs.map((d) => ({ id: d.id, ...(d.data() as Omit<Tenant, 'id'>) }));
  } catch (err) {
    handleFirestoreError(err, OperationType.LIST, colPath);
  }
}

export async function createTenant(
  ownerUid: string,
  data: Omit<Tenant, 'id' | 'ownerUid' | 'createdAt' | 'updatedAt'>
): Promise<string> {
  const colPath = 'tenants';
  try {
    const newDocRef = doc(collection(db, colPath));
    const now = new Date().toISOString();
    const payload: Omit<Tenant, 'id'> = {
      ...data,
      ownerUid,
      createdAt: now,
      updatedAt: now,
    };
    await setDoc(newDocRef, payload);
    return newDocRef.id;
  } catch (err) {
    handleFirestoreError(err, OperationType.CREATE, colPath);
  }
}

export async function updateTenant(
  tenantId: string,
  data: Partial<Tenant>
): Promise<void> {
  const docPath = `tenants/${tenantId}`;
  try {
    const docRef = doc(db, 'tenants', tenantId);
    await updateDoc(docRef, {
      ...data,
      updatedAt: new Date().toISOString(),
    });
  } catch (err) {
    handleFirestoreError(err, OperationType.UPDATE, docPath);
  }
}

export async function deactivateTenant(tenantId: string): Promise<void> {
  return updateTenant(tenantId, { active: false });
}

// ========================
// PAYMENTS
// ========================

export async function fetchPayments(ownerUid: string, period?: string): Promise<Payment[]> {
  const colPath = 'payments';
  try {
    let q = query(collection(db, colPath), where('ownerUid', '==', ownerUid));
    if (period) {
      q = query(collection(db, colPath), where('ownerUid', '==', ownerUid), where('period', '==', period));
    }
    const snap = await getDocs(q);
    return snap.docs.map((d) => ({ id: d.id, ...(d.data() as Omit<Payment, 'id'>) }));
  } catch (err) {
    handleFirestoreError(err, OperationType.LIST, colPath);
  }
}

/**
 * Idempotently generates monthly payment documents for all active properties for a given period.
 * Document ID format: `${propertyId}_${period}`
 */
export async function ensureMonthlyPayments(
  ownerUid: string,
  properties: Property[],
  period: string = getCurrentPeriodSantoDomingo()
): Promise<number> {
  const colPath = 'payments';
  let createdCount = 0;

  for (const prop of properties) {
    if (!prop.active) continue;

    // Check lease period boundary
    const today = getTodaySantoDomingo();
    if (prop.leaseStartDate && prop.leaseStartDate.substring(0, 7) > period) {
      continue;
    }
    if (prop.leaseEndDate && prop.leaseEndDate.substring(0, 7) < period) {
      continue;
    }

    const deterministicId = `${prop.id}_${period}`;
    const docRef = doc(db, colPath, deterministicId);

    try {
      const snap = await getDoc(docRef);
      if (!snap.exists()) {
        const dueDate = calculateDueDate(period, prop.dueDay);
        const paymentPayload: Omit<Payment, 'id'> = {
          ownerUid,
          propertyId: prop.id,
          tenantId: prop.tenantId || undefined,
          period,
          amountDue: prop.monthlyRentAmount,
          dueDate,
          status: 'pending',
          paidAt: null,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
        };
        await setDoc(docRef, paymentPayload);
        createdCount++;
      }
    } catch (err) {
      handleFirestoreError(err, OperationType.WRITE, `${colPath}/${deterministicId}`);
    }
  }

  return createdCount;
}

/**
 * Marks a payment as paid. Immutable transition verified by Security Rules.
 */
export async function markPaymentAsPaid(payment: Payment): Promise<void> {
  const docPath = `payments/${payment.id}`;
  try {
    const docRef = doc(db, 'payments', payment.id);
    const now = new Date().toISOString();
    await updateDoc(docRef, {
      status: 'paid',
      paidAt: now,
      updatedAt: now,
    });
  } catch (err) {
    handleFirestoreError(err, OperationType.UPDATE, docPath);
  }
}

// ========================
// REMINDER LOGS
// ========================

export async function fetchReminderLogs(ownerUid: string): Promise<ReminderLog[]> {
  const colPath = 'reminderLogs';
  try {
    const q = query(collection(db, colPath), where('ownerUid', '==', ownerUid));
    const snap = await getDocs(q);
    return snap.docs.map((d) => ({ id: d.id, ...(d.data() as Omit<ReminderLog, 'id'>) }));
  } catch (err) {
    handleFirestoreError(err, OperationType.LIST, colPath);
  }
}

// ========================
// SETTINGS
// ========================

export async function fetchOwnerSettings(ownerUid: string): Promise<OwnerSettings | null> {
  const docPath = `settings/${ownerUid}`;
  try {
    const docRef = doc(db, 'settings', ownerUid);
    const snap = await getDoc(docRef);
    if (!snap.exists()) {
      return {
        ownerUid,
        notificationEmail: 'mimelfis.lopez@gmail.com',
        reminderHour: 8,
        timezone: 'America/Santo_Domingo',
        updatedAt: new Date().toISOString(),
      };
    }
    return { id: snap.id, ...(snap.data() as Omit<OwnerSettings, 'id'>) };
  } catch (err) {
    handleFirestoreError(err, OperationType.GET, docPath);
  }
}

export async function saveOwnerSettings(ownerUid: string, data: Partial<OwnerSettings>): Promise<void> {
  const docPath = `settings/${ownerUid}`;
  try {
    const docRef = doc(db, 'settings', ownerUid);
    const now = new Date().toISOString();
    const payload = {
      ownerUid,
      notificationEmail: data.notificationEmail || 'mimelfis.lopez@gmail.com',
      reminderHour: data.reminderHour ?? 8,
      timezone: data.timezone || 'America/Santo_Domingo',
      updatedAt: now,
    };
    await setDoc(docRef, payload, { merge: true });
  } catch (err) {
    handleFirestoreError(err, OperationType.WRITE, docPath);
  }
}
