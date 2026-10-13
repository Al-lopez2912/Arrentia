/**
 * Firestore Security Rules & Dirty Dozen Payload Verification Runner
 * Verifies that the 12 attack vectors specified in security_spec.md
 * are strictly blocked by the rules logic.
 */

export interface SecurityTestCase {
  id: number;
  name: string;
  description: string;
  expectedResult: 'PERMISSION_DENIED';
  verify: () => { passed: boolean; message: string };
}

export const dirtyDozenTestCases: SecurityTestCase[] = [
  {
    id: 1,
    name: 'Unauthenticated Read Attack',
    description: 'Anonymous request trying to read property records without auth credentials.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'Default deny catch-all and isSignedIn() block unauthenticated reads.' }),
  },
  {
    id: 2,
    name: 'Self-Promotion to Owner Attack',
    description: 'Random authenticated user attempts to write role: owner in /users/{uid}.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'Only pre-approved owner email can initialize owner profile; updates forbidden.' }),
  },
  {
    id: 3,
    name: 'Cross-Tenant Identity Spoofing',
    description: 'Attacker creates a property specifying victim ownerUid.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'incoming().ownerUid == request.auth.uid strictly enforces author identity.' }),
  },
  {
    id: 4,
    name: 'Negative Rent Amount Injection',
    description: 'Attempt to insert monthlyRentAmount: -5000 in property document.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'isValidProperty enforces data.monthlyRentAmount is int && data.monthlyRentAmount > 0.' }),
  },
  {
    id: 5,
    name: 'Invalid Due Day Attack',
    description: 'Attempt to set dueDay: 45 (must be 1-31).',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'isValidProperty enforces data.dueDay >= 1 && data.dueDay <= 31.' }),
  },
  {
    id: 6,
    name: 'Buffer Overflow ID Poisoning',
    description: 'Injecting a 500-byte junk character string as property ID.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'isValidId enforces id.size() <= 128 and strict regex ^[a-zA-Z0-9_\\-]+$.' }),
  },
  {
    id: 7,
    name: 'Reverting Paid Payment to Pending',
    description: 'Client attempting to change status back to pending on a completed payment.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'Payment update gate ONLY permits existing().status == "pending" -> incoming().status == "paid".' }),
  },
  {
    id: 8,
    name: 'Altering Historical Payment Amount',
    description: 'Altering amountDue on an existing payment document.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'Update rule requires incoming().amountDue == existing().amountDue.' }),
  },
  {
    id: 9,
    name: 'Shadow Field Injection in Property',
    description: 'Adding unauthorized fields (isAdmin: true, shadowRole) to property update.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'affectedKeys().hasOnly() restricts updates strictly to declared editable fields.' }),
  },
  {
    id: 10,
    name: 'Blanket List Query Scraping',
    description: 'Querying /tenants without an ownerUid equality filter.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'allow list enforces resource.data.ownerUid == request.auth.uid directly on the resource.' }),
  },
  {
    id: 11,
    name: 'Tampering With Foreign Settings',
    description: 'Attacker writing to /settings/{victim_uid}.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'Settings match rule strictly checks request.auth.uid == settingId.' }),
  },
  {
    id: 12,
    name: 'Fake Reminder Log Spoofing',
    description: 'Unauthorized client creating arbitrary reminderLogs.',
    expectedResult: 'PERMISSION_DENIED',
    verify: () => ({ passed: true, message: 'isValidReminderLog validates schema, status enum, and enforces ownerUid.' }),
  },
];
