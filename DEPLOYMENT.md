# Guía de Despliegue en Producción — Control de Alquileres

**Aplicación:** Control de Alquileres  
**Propietario Autorizado:** erickfeliz2026startup@gmail.com  
**Moneda:** Pesos Dominicanos (DOP / RD$)  
**Zona Horaria:** America/Santo_Domingo (AST, UTC-4)  
**ID de Proyecto Firebase:** spartan-outcome-rhh41  

---

## 1. Prerrequisitos y Plan de Firebase / Google Cloud

1. **Plan de Facturación (Blaze Plan)**:
   - Para desplegar Cloud Functions (2da generación) y Cloud Scheduler es necesario tener habilitado el plan **Blaze (Pay-as-you-go)** en Firebase / Google Cloud.
   - Las cuotas gratuitas mensuales cubren holgadamente las necesidades de este MVP (2M de invocaciones Cloud Functions gratuitas al mes y 3 jobs de Cloud Scheduler gratis).

2. **Herramientas de Línea de Comandos**:
   ```bash
   npm install -g firebase-tools
   firebase login
   ```

---

## 2. Configuración de Firebase Authentication

- En la consola de Firebase: **Authentication > Sign-in method**.
- **Proveedor Google:** Habilitado.
- **Registro público:** Deshabilitado en la aplicación cliente mediante reglas Zero-Trust; la interfaz solo autoriza la cuenta del propietario `erickfeliz2026startup@gmail.com`.
- **Dominios autorizados:** Verificar que el dominio de producción y desarrollo de AI Studio / Cloud Run figure en la lista de dominios permitidos de Firebase Auth.

---

## 3. Configuración de Cloud Firestore y Reglas de Seguridad

- **Base de datos provisionada:** `ai-studio-controldealquile-263d6e4c-2901-459e-bdaf-6ae980831095` en el proyecto `spartan-outcome-rhh41`.
- **Reglas de Seguridad**:
  El archivo `firestore.rules` ya implementa las 8 columnas de seguridad ABAC, validación estricta de esquemas y denegación por defecto.
  Para desplegar o actualizar reglas en cualquier momento:
  ```bash
  firebase deploy --only firestore:rules
  ```

### Índices de Firestore Requeridos
En caso de ejecutar consultas combinadas compuestas (por ejemplo `ownerUid` + `period`), Firestore generará un enlace directo en la consola para crearlo con un solo clic si no existe.

---

## 4. Configuración del Proveedor de Correo (Resend)

1. Crear una cuenta en [https://resend.com](https://resend.com).
2. Generar una clave de API (**API Key**) con permisos de envío (`Full Access` o `Sending access`).
3. Verificar el dominio remitente en la sección **Domains** de Resend agregando los registros DNS correspondientes (DKIM, SPF y DMARC). Para pruebas iniciales, Resend permite enviar desde `onboarding@resend.dev` a la dirección registrada.

---

## 5. Configuración de Secretos en el Servidor (Secret Manager)

**Nunca coloques la clave de API en el código fuente ni en el frontend.**

Para configurar la clave en Cloud Functions (2da generación):
```bash
firebase functions:secrets:set RESEND_API_KEY
# Escribe la clave cuando se solicite (ej. re_xxxxxxxxxx)
```

Para el servidor Express local o en contenedor:
Configura en `.env`:
```env
RESEND_API_KEY="re_xxxxxxxxxxxxxx"
```

---

## 6. Despliegue de Cloud Functions (2da Generación) y Cloud Scheduler

El directorio `functions/` contiene el código TypeScript de la función programada `scheduledDailyRentalReminder` y el endpoint HTTPS autenticado `manualRentalReminderTrigger`.

### Pasos de despliegue:
```bash
cd functions
npm install
npm run build
firebase deploy --only functions
```

### Comprobación de Cloud Scheduler:
- La función se configura automáticamente con `timeZone: "America/Santo_Domingo"` y horario `0 8 * * *` (todos los días a las 8:00 AM AST).
- Puedes comprobar y ejecutar manualmente la programación desde la consola de Google Cloud: **Cloud Scheduler > scheduledDailyRentalReminder > Force Run**.

---

## 7. Ejecución Local y Desarrollo

1. Instalar dependencias:
   ```bash
   npm install
   ```
2. Iniciar servidor full-stack (Express + Vite en puerto 3000):
   ```bash
   npm run dev
   ```
3. Construir para producción:
   ```bash
   npm run build
   npm start
   ```

---

## 8. Estrategia de Recuperación y Resiliencia (Recovery Strategy)

1. **Idempotencia de Obligaciones**:
   - Cada pago mensual utiliza el identificador determinístico `${propertyId}_${period}` (por ejemplo `prop1_2026-10`).
   - Si la tarea programada se ejecuta varias veces, nunca se crean pagos duplicados para el mismo mes.

2. **Bloqueo Atómico de Recordatorios**:
   - La colección `reminderLogs` reserva de forma atómica el estado `processing` antes de invocar la API de Resend.
   - Si un envío ya tiene estado `sent`, la rutina omite el envío inmediatamente, garantizando que el propietario reciba como máximo un recordatorio por alquiler pendiente.
   - Si un pago ya fue marcado como `paid`, ningún recordatorio se envía.

3. **Reintentos en Caso de Falla de Red**:
   - Si la llamada a Resend falla, el estado se guarda como `failed` con el mensaje de error sanitizado y el contador de `attempts`.
   - La función programada tiene `retryCount: 2` para reintentos transitorios controlados.

---

## 9. Lista de Verificación de Aceptación (Acceptance Test Checklist)

- [x] **Autenticación:** El propietario `erickfeliz2026startup@gmail.com` puede iniciar sesión con Google. Intentos desde correos no autorizados son bloqueados.
- [x] **Propiedades:** Registro, edición y archivado de propiedades con montos positivos en DOP y días de pago válidos (1-31).
- [x] **Inquilinos:** Registro de inquilinos y vinculación unívoca con propiedades activas.
- [x] **Generación de Pagos:** Generación determinística de obligaciones mensuales para todas las propiedades activas.
- [x] **Marcado como Pagado:** Transición inmutable de `pending` a `paid` con registro del sello de tiempo del servidor.
- [x] **Cálculo de Vencimiento:** Ajuste automático a fin de mes para febrero (28 o 29) y meses de 30 días.
- [x] **Detección de Vencidos:** Derivación precisa de pagos vencidos según la fecha actual en America/Santo_Domingo.
- [x] **Envío de Prueba de Correo:** Capacidad de enviar un correo de prueba con la plantilla oficial al buzón del propietario.
- [x] **Auditoría de Seguridad:** Ejecución de pruebas contra peticiones no autenticadas (HTTP 401) y verificación de los 12 vectores "Dirty Dozen".
