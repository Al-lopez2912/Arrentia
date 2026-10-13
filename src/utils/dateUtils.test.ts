import { calculateDueDate, isPaymentOverdue, isPaymentDueToday, formatCurrencyDOP } from './dateUtils';

export function runDateAndPaymentTests() {
  const results: { test: string; passed: boolean; message?: string }[] = [];

  function assert(condition: boolean, testName: string, detail?: string) {
    results.push({
      test: testName,
      passed: condition,
      message: condition ? 'OK' : detail || 'Assertion failed',
    });
  }

  // 1. Leap year February clamp
  const feb2024 = calculateDueDate('2024-02', 31);
  assert(feb2024 === '2024-02-29', 'Bisiesto 2024: día 31 se ajusta a 2024-02-29', `Obtenido: ${feb2024}`);

  // 2. Non-leap year February clamp
  const feb2026 = calculateDueDate('2026-02', 31);
  assert(feb2026 === '2026-02-28', 'No bisiesto 2026: día 31 se ajusta a 2026-02-28', `Obtenido: ${feb2026}`);

  // 3. 30-day month clamp (April 31 -> April 30)
  const apr31 = calculateDueDate('2026-04', 31);
  assert(apr31 === '2026-04-30', 'Mes de 30 días: abril 31 se ajusta a 2026-04-30', `Obtenido: ${apr31}`);

  // 4. Normal day in 31-day month
  const oct15 = calculateDueDate('2026-10', 15);
  assert(oct15 === '2026-10-15', 'Día normal: octubre 15 se mantiene 2026-10-15', `Obtenido: ${oct15}`);

  // 5. Overdue payment calculation
  const overdueCheck = isPaymentOverdue('2026-10-10', 'pending', '2026-10-13');
  assert(overdueCheck === true, 'Pago con fecha pasada y status pendiente es vencido');

  const paidNotOverdue = isPaymentOverdue('2026-10-10', 'paid', '2026-10-13');
  assert(paidNotOverdue === false, 'Pago ya completado no se considera vencido');

  const futureNotOverdue = isPaymentOverdue('2026-10-20', 'pending', '2026-10-13');
  assert(futureNotOverdue === false, 'Pago con vencimiento futuro no es vencido');

  // 6. Due today calculation
  const dueTodayCheck = isPaymentDueToday('2026-10-13', 'pending', '2026-10-13');
  assert(dueTodayCheck === true, 'Pago con vencimiento hoy es vencido hoy');

  // 7. Currency formatting
  const formattedDop = formatCurrencyDOP(25000);
  assert(formattedDop.includes('25') && formattedDop.includes('000'), 'Formateo de moneda DOP contiene dígitos esperados');

  return results;
}
