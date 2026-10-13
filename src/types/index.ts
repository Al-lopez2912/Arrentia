export type PaymentStatus = 'pending' | 'paid';
export type ReminderStatus = 'processing' | 'sent' | 'failed';

export interface UserProfile {
  uid: string;
  email: string;
  role: 'owner';
  createdAt: string;
}

export interface Property {
  id: string;
  ownerUid: string;
  name: string;
  address: string;
  monthlyRentAmount: number; // in integer DOP
  dueDay: number; // 1-31
  tenantId?: string | null;
  leaseStartDate: string; // YYYY-MM-DD
  leaseEndDate?: string | null; // YYYY-MM-DD
  active: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface Tenant {
  id: string;
  ownerUid: string;
  fullName: string;
  phone: string;
  email?: string;
  propertyId?: string | null;
  notes?: string;
  active: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface Payment {
  id: string; // ${propertyId}_${period}
  ownerUid: string;
  propertyId: string;
  tenantId?: string;
  period: string; // YYYY-MM
  amountDue: number; // in integer DOP
  dueDate: string; // YYYY-MM-DD
  status: PaymentStatus;
  paidAt?: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface ReminderLog {
  id: string;
  ownerUid: string;
  paymentId: string;
  propertyId: string;
  period: string;
  recipient: string;
  scheduledFor: string; // YYYY-MM-DD
  status: ReminderStatus;
  providerMessageId?: string;
  attempts: number;
  lastError?: string;
  createdAt: string;
  updatedAt: string;
}

export interface OwnerSettings {
  id?: string;
  ownerUid: string;
  notificationEmail: string;
  reminderHour: number; // default 8
  timezone: string; // America/Santo_Domingo
  resendApiKeyConfigured?: boolean;
  updatedAt: string;
}

export enum OperationType {
  CREATE = 'create',
  UPDATE = 'update',
  DELETE = 'delete',
  LIST = 'list',
  GET = 'get',
  WRITE = 'write',
}

export interface FirestoreErrorInfo {
  error: string;
  operationType: OperationType;
  path: string | null;
  authInfo: {
    userId?: string | null;
    email?: string | null;
    emailVerified?: boolean | null;
    isAnonymous?: boolean | null;
    tenantId?: string | null;
    providerInfo?: {
      providerId?: string | null;
      email?: string | null;
    }[];
  };
}
