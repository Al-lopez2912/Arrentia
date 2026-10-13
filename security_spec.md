# Security Specification — Control de Alquileres

## 1. Data Invariants
1. **Single Authorized Owner Principle**: Only the designated owner (`role == 'owner'`) can read, create, or update records. Public and anonymous writes are strictly denied.
2. **Identity Integrity**: All tenant, property, payment, and setting documents must have `ownerUid == request.auth.uid`. A user cannot forge another user's UID or create records for someone else.
3. **Role Immutability & Anti-Escalation**: Users cannot self-assign `role = 'owner'`. Only verified initial setup or pre-approved admin role allows owner status. Regular users cannot alter the `role` field.
4. **Deterministic Payment IDs**: Payment document IDs follow `${propertyId}_${period}` format to guarantee idempotency and avoid duplicate payments in the same calendar month.
5. **State Machine Integrity (Payments)**:
   - Status may only be `pending` or `paid`.
   - Once a payment is marked `paid`, it cannot be reverted to `pending` via client SDK.
   - When transitioning to `paid`, `paidAt` must be present and immutable thereafter.
6. **Property Integrity**:
   - `monthlyRentAmount` must be an integer > 0.
   - `dueDay` must be an integer between 1 and 31.
   - `leaseStartDate` must be a valid date format.
7. **Tenant Integrity**:
   - `fullName` is required (size between 2 and 120 chars).
   - `phone` is required (size between 7 and 30 chars).
8. **Denial of Wallet Protection**: All string fields and IDs are strictly length-bounded (IDs <= 128 chars).

## 2. The "Dirty Dozen" Malicious Payloads

1. **Payload 1: Unauthenticated Read**
   - Operation: `get(/properties/prop1)` with `request.auth = null`.
   - Expected: PERMISSION_DENIED.
2. **Payload 2: Self-Promotion to Owner**
   - Operation: `create(/users/attacker_uid)` with `{ uid: "attacker_uid", email: "attacker@evil.com", role: "owner" }`.
   - Expected: PERMISSION_DENIED.
3. **Payload 3: Cross-Tenant Property Creation (Identity Spoofing)**
   - Operation: `create(/properties/prop1)` with `{ ownerUid: "victim_owner_uid", name: "Casa Maliciosa", ... }` by user with `uid: "attacker_uid"`.
   - Expected: PERMISSION_DENIED.
4. **Payload 4: Negative Rent Amount Injection**
   - Operation: `create(/properties/prop2)` with `{ monthlyRentAmount: -5000, dueDay: 15, ... }`.
   - Expected: PERMISSION_DENIED.
5. **Payload 5: Invalid Due Day (> 31)**
   - Operation: `create(/properties/prop3)` with `{ monthlyRentAmount: 18000, dueDay: 45, ... }`.
   - Expected: PERMISSION_DENIED.
6. **Payload 6: Buffer-Overflow ID Attack (ID Poisoning)**
   - Operation: `create(/properties/` + "A"*500 + `)` with valid data.
   - Expected: PERMISSION_DENIED.
7. **Payload 7: Reverting Paid Payment to Pending (State Tampering)**
   - Operation: `update(/payments/prop1_2026-10)` from `{ status: "paid" }` to `{ status: "pending", paidAt: null }`.
   - Expected: PERMISSION_DENIED.
8. **Payload 8: Altering Historical Payment Amount After Payment**
   - Operation: `update(/payments/prop1_2026-10)` from `{ amountDue: 25000, status: "paid" }` to `{ amountDue: 5000 }`.
   - Expected: PERMISSION_DENIED.
9. **Payload 9: Shadow Field Injection in Property Update**
   - Operation: `update(/properties/prop1)` with `{ active: true, isAdmin: true, bypassSecurity: true }`.
   - Expected: PERMISSION_DENIED.
10. **Payload 10: Unauthorized Blanket Query (Query Scraping)**
    - Operation: `list(/tenants)` without `where("ownerUid", "==", auth.uid)`.
    - Expected: PERMISSION_DENIED.
11. **Payload 11: Tampering with Another Owner's Settings**
    - Operation: `setDoc(/settings/victim_owner_uid)` by `attacker_uid`.
    - Expected: PERMISSION_DENIED.
12. **Payload 12: Fake Reminder Status Spoofing**
    - Operation: `create(/reminderLogs/log1)` with fake recipient or without proper owner authorization.
    - Expected: PERMISSION_DENIED.
