export const SANTO_DOMINGO_TZ = 'America/Santo_Domingo';

/**
 * Returns today's date formatted as YYYY-MM-DD in the America/Santo_Domingo timezone.
 */
export function getTodaySantoDomingo(customDate: Date = new Date()): string {
  const formatter = new Intl.DateTimeFormat('en-CA', {
    timeZone: SANTO_DOMINGO_TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  });
  return formatter.format(customDate);
}

/**
 * Returns the current period formatted as YYYY-MM in America/Santo_Domingo.
 */
export function getCurrentPeriodSantoDomingo(customDate: Date = new Date()): string {
  const today = getTodaySantoDomingo(customDate);
  return today.substring(0, 7);
}

/**
 * Calculates the exact due date for a given period (YYYY-MM) and dueDay (1-31).
 * Clamps to the last day of the month if dueDay exceeds the month's days
 * (e.g. Feb 30 becomes Feb 28 or Feb 29 in leap years).
 */
export function calculateDueDate(period: string, dueDay: number): string {
  const [yearStr, monthStr] = period.split('-');
  const year = parseInt(yearStr, 10);
  const month = parseInt(monthStr, 10); // 1-indexed

  // Day 0 of next month gives the last day of the current month
  const lastDayOfMonth = new Date(year, month, 0).getDate();
  const clampedDay = Math.min(Math.max(dueDay, 1), lastDayOfMonth);

  const formattedMonth = String(month).padStart(2, '0');
  const formattedDay = String(clampedDay).padStart(2, '0');
  return `${year}-${formattedMonth}-${formattedDay}`;
}

/**
 * Checks if a pending payment is overdue relative to today in Santo Domingo.
 */
export function isPaymentOverdue(dueDate: string, status: string, today: string = getTodaySantoDomingo()): boolean {
  if (status !== 'pending') return false;
  return dueDate < today;
}

/**
 * Checks if a pending payment is due today in Santo Domingo.
 */
export function isPaymentDueToday(dueDate: string, status: string, today: string = getTodaySantoDomingo()): boolean {
  if (status !== 'pending') return false;
  return dueDate === today;
}

/**
 * Formats monetary amounts in Dominican Pesos (DOP).
 * Examples: RD$ 25,000
 */
export function formatCurrencyDOP(amount: number): string {
  const formatted = new Intl.NumberFormat('es-DO', {
    style: 'currency',
    currency: 'DOP',
    minimumFractionDigits: 0,
    maximumFractionDigits: 0,
  }).format(amount);

  return formatted;
}

/**
 * Formats a YYYY-MM period into Spanish readable text, e.g. "Octubre 2026".
 */
export function formatPeriodSpanish(period: string): string {
  const [yearStr, monthStr] = period.split('-');
  const monthNames = [
    'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
    'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
  ];
  const monthIndex = parseInt(monthStr, 10) - 1;
  return `${monthNames[monthIndex] || ''} ${yearStr}`;
}

/**
 * Formats a YYYY-MM-DD date into Spanish readable format.
 */
export function formatDateSpanish(dateStr: string): string {
  if (!dateStr) return '';
  const [year, month, day] = dateStr.split('-');
  const monthNames = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
  ];
  const mIndex = parseInt(month, 10) - 1;
  return `${parseInt(day, 10)} de ${monthNames[mIndex] || month} de ${year}`;
}
