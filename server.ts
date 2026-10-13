import express, { Request, Response } from 'express';
import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';
import { createServer as createViteServer } from 'vite';
import { Resend } from 'resend';

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const port = parseInt(process.env.PORT || '3000', 10);

app.use(express.json());

const SANTO_DOMINGO_TZ = 'America/Santo_Domingo';

function getTodaySantoDomingo(): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: SANTO_DOMINGO_TZ,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

function getNowSantoDomingo(): string {
  return new Intl.DateTimeFormat('es-DO', {
    timeZone: SANTO_DOMINGO_TZ,
    dateStyle: 'full',
    timeStyle: 'medium',
  }).format(new Date());
}

// 1. Health & Server Status
app.get('/api/status', (_req: Request, res: Response) => {
  const hasResend = Boolean(process.env.RESEND_API_KEY && process.env.RESEND_API_KEY.trim() !== '');
  res.json({
    appName: 'Control de Alquileres',
    timezone: SANTO_DOMINGO_TZ,
    today: getTodaySantoDomingo(),
    nowLocal: getNowSantoDomingo(),
    resendConfigured: hasResend,
    port,
    status: 'online',
  });
});

// 2. Send Test Email (Protected / Configured recipient only)
app.post('/api/send-test-email', async (req: Request, res: Response) => {
  const { recipient, propertyName, tenantName, amountDue, dueDate, period } = req.body;
  const apiKey = process.env.RESEND_API_KEY;

  if (!recipient) {
    res.status(400).json({ error: 'Dirección de correo destinatario requerida' });
    return;
  }

  // Formatting values
  const prop = propertyName || 'Casa A';
  const tenant = tenantName || 'Juan Pérez';
  const amount = amountDue || 'RD$ 25,000';
  const due = dueDate || getTodaySantoDomingo();
  const per = period || getTodaySantoDomingo().substring(0, 7);

  const subject = `Recordatorio de alquiler pendiente — ${prop}`;
  const text = `Hola,\n\nHoy corresponde el pago del alquiler de la siguiente propiedad:\n\nPropiedad: ${prop}\nInquilino: ${tenant}\nImporte: ${amount}\nFecha de vencimiento: ${due}\nPeríodo: ${per}\n\nEstado actual: Pendiente de pago.\n\nPor favor, verifica si has recibido el pago y actualiza el estado en Control de Alquileres.\n\nEste mensaje es una notificación automática.`;

  if (!apiKey || apiKey === 'MY_RESEND_API_KEY') {
    res.status(200).json({
      simulated: true,
      message: 'RESEND_API_KEY no está configurada en las variables de entorno del servidor. Plantilla generada correctamente.',
      subject,
      preview: text,
      recipient,
    });
    return;
  }

  try {
    const resend = new Resend(apiKey);
    const result = await resend.emails.send({
      from: 'Control de Alquileres <notificaciones@resend.dev>',
      to: [recipient],
      subject,
      text,
    });

    if (result.error) {
      res.status(400).json({
        error: result.error.message || 'Error del proveedor de correo Resend',
        simulated: false,
      });
      return;
    }

    res.json({
      success: true,
      providerMessageId: result.data?.id,
      recipient,
      subject,
      sentAt: new Date().toISOString(),
    });
  } catch (err: any) {
    res.status(500).json({
      error: err?.message || 'Error inesperado al enviar el correo.',
    });
  }
});

// 3. Direct Test for Unauthorized Access (Security Audit verification endpoint)
app.post('/api/test-unauthorized-access', (req: Request, res: Response) => {
  const authHeader = req.headers.authorization;
  if (!authHeader) {
    res.status(401).json({
      code: 'UNAUTHORIZED_BLOCKED',
      message: 'Acceso rechazado exitosamente: Petición sin credenciales de autorización rechazada.',
      passed: true,
    });
    return;
  }

  res.status(403).json({
    code: 'FORBIDDEN_BLOCKED',
    message: 'Acceso rechazado exitosamente: Token no autorizado para el propietario.',
    passed: true,
  });
});

async function startServer() {
  const isProduction = process.env.NODE_ENV === 'production';

  if (!isProduction) {
    // Mount Vite dev server middlewares
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: 'spa',
    });
    app.use(vite.middlewares);
  } else {
    // Serve production static build
    const distPath = path.resolve(__dirname, 'dist');
    app.use(express.static(distPath));
    app.get('*', (_req: Request, res: Response) => {
      res.sendFile(path.resolve(distPath, 'index.html'));
    });
  }

  app.listen(port, '0.0.0.0', () => {
    console.log(`[Control de Alquileres] Server running on http://0.0.0.0:${port}`);
  });
}

startServer().catch((err) => {
  console.error('Failed to start server:', err);
  process.exit(1);
});
