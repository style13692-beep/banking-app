const express = require('express');
const cors = require('cors');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const { DefaultAzureCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');

const app = express();

// ── CORS: only allow your frontend domain ──────────────────────────────────
const ALLOWED_ORIGINS = [
  'https://lumebank-project.australiaeast.cloudapp.azure.com',
  // Add your Azure Static Web App URL here too, e.g.:
  // 'https://your-app-name.azurestaticapps.net'
];

app.use(cors({
  origin: function (origin, callback) {
    // Allow requests with no origin (mobile apps, curl, Postman)
    if (!origin || ALLOWED_ORIGINS.includes(origin)) {
      callback(null, true);
    } else {
      callback(new Error('Not allowed by CORS'));
    }
  },
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization']
}));

app.options('*', cors({
  origin: ALLOWED_ORIGINS,
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization']
}));

app.use(express.json());

// ── Frontend: serve from a relative path, not a hardcoded one ─────────────
const FRONTEND_DIR = path.join(__dirname, 'public'); // Put your HTML/CSS/JS in a "public" folder
app.use(express.static(FRONTEND_DIR));
app.get('/', (req, res) => {
  res.sendFile(path.join(FRONTEND_DIR, 'index.html'));
});

// ── Azure Key Vault ────────────────────────────────────────────────────────
const keyVaultUrl = "https://lume-bank-vault.vault.azure.net";
const credential = new DefaultAzureCredential();
const secretClient = new SecretClient(keyVaultUrl, credential);

// ── Users file ────────────────────────────────────────────────────────────
const USERS_FILE = path.join(__dirname, 'users.json');

// Simple file lock to prevent concurrent write corruption
let writeLock = false;
const writeQueue = [];

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) {
    fs.writeFileSync(USERS_FILE, JSON.stringify([]));
  }
  return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
}

function saveUsers(users) {
  return new Promise((resolve, reject) => {
    const doWrite = () => {
      writeLock = true;
      fs.writeFile(USERS_FILE, JSON.stringify(users, null, 2), (err) => {
        writeLock = false;
        if (writeQueue.length > 0) writeQueue.shift()();
        if (err) reject(err);
        else resolve();
      });
    };
    if (writeLock) {
      writeQueue.push(doWrite);
    } else {
      doWrite();
    }
  });
}

// ── TLS ───────────────────────────────────────────────────────────────────
const DOMAIN = 'lumebank-project.australiaeast.cloudapp.azure.com';
const CERT_PATH = 'C:/lume-bank/certs';
const certKeyPath  = path.join(CERT_PATH, `${DOMAIN}-key.pem`);
const certFilePath = path.join(CERT_PATH, 'fullchain.pem'); // match what win-acme actually generated

// ── Health check ──────────────────────────────────────────────────────────
app.get('/api/health', (req, res) => {
  res.json({ status: 'online', keyVault: 'connected', azureAD: 'enabled' });
});

async function startServer() {
  const [TENANT_ID, CLIENT_ID, AD_CLIENT_SECRET, JWT_SECRET, AZURE_REDIRECT_URI] = await Promise.all([
    secretClient.getSecret("tenant-id").then(s => s.value),
    secretClient.getSecret("client-id").then(s => s.value),
    secretClient.getSecret("azure-ad-client-secret").then(s => s.value),
    secretClient.getSecret("jwt-secret").then(s => s.value),
    secretClient.getSecret("azure-redirect-uri").then(s => s.value)
  ]);

  if (!TENANT_ID || !CLIENT_ID || !AD_CLIENT_SECRET || !JWT_SECRET || !AZURE_REDIRECT_URI) {
    console.error("Missing required secrets from Key Vault");
    process.exit(1);
  }

  console.log("✅ Secrets loaded from Azure Key Vault");

  // ── Config endpoint (safe to expose — no secrets) ──────────────────────
  app.get('/api/config', (req, res) => {
    res.json({
      tenantId:    TENANT_ID,
      clientId:    CLIENT_ID,
      redirectUri: AZURE_REDIRECT_URI
    });
  });

  // ── Register ──────────────────────────────────────────────────────────
  app.post('/api/register', async (req, res) => {
    const { firstName, lastName, email, password, phone, dob, address, accountType } = req.body;

    if (!firstName || !password || !email) {
      return res.status(400).json({ success: false, message: 'First name, email and password are required' });
    }

    // Basic email format check
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return res.status(400).json({ success: false, message: 'Invalid email address' });
    }

    if (password.length < 8) {
      return res.status(400).json({ success: false, message: 'Password must be at least 8 characters' });
    }

    const users = loadUsers();
    const existing = users.find(u => u.email.toLowerCase() === email.toLowerCase());

    if (existing) {
      return res.status(409).json({ success: false, message: 'An account with this email already exists' });
    }

    const hashedPassword = await bcrypt.hash(password, 12); // 12 rounds is stronger than 10

    const newUser = {
      id: Date.now().toString(),
      firstName,
      lastName,
      email: email.toLowerCase(), // always store lowercase
      phone,
      dob,
      address,
      accountType,
      password: hashedPassword,
      createdAt: new Date().toISOString()
    };

    users.push(newUser);
    await saveUsers(users);

    const token = jwt.sign(
      { id: newUser.id, email: newUser.email, firstName, lastName },
      JWT_SECRET,
      { expiresIn: '1h' }
    );

    res.json({ success: true, token, user: { firstName, lastName, email: newUser.email } });
  });

  // ── Login ─────────────────────────────────────────────────────────────
  app.post('/api/login', async (req, res) => {
    const { username, password } = req.body;

    if (!username || !password) {
      return res.status(400).json({ error: 'Email and password required' });
    }

    const users = loadUsers();
    // FIXED: match by email only — not by first name (security issue)
    const user = users.find(u => u.email.toLowerCase() === username.toLowerCase());

    if (!user) return res.status(401).json({ error: 'Invalid credentials' });

    const valid = await bcrypt.compare(password, user.password);
    if (!valid) return res.status(401).json({ error: 'Invalid credentials' });

    const token = jwt.sign(
      { id: user.id, email: user.email, firstName: user.firstName, lastName: user.lastName },
      JWT_SECRET,
      { expiresIn: '1h' }
    );

    res.json({
      success: true,
      token,
      username: user.firstName,
      user: { firstName: user.firstName, lastName: user.lastName, email: user.email }
    });
  });

  // ── Azure AD OAuth ────────────────────────────────────────────────────
  app.post('/api/auth/azure', async (req, res) => {
    const { code } = req.body;
    if (!code) return res.status(400).json({ error: 'Authorization code required' });

    try {
      const postData = new URLSearchParams({
        client_id: CLIENT_ID,
        client_secret: AD_CLIENT_SECRET,
        code,
        redirect_uri: AZURE_REDIRECT_URI,
        grant_type: 'authorization_code'
      }).toString();

      const tokenResponse = await new Promise((resolve, reject) => {
        const options = {
          hostname: 'login.microsoftonline.com',
          path: `/${TENANT_ID}/oauth2/v2.0/token`,
          method: 'POST',
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Content-Length': Buffer.byteLength(postData)
          }
        };
        const request = https.request(options, (response) => {
          let data = '';
          response.on('data', chunk => data += chunk);
          response.on('end', () => {
            try { resolve(JSON.parse(data)); }
            catch (e) { reject(new Error('Invalid JSON from Azure AD')); }
          });
        });
        request.on('error', reject);
        request.write(postData);
        request.end();
      });

      if (tokenResponse.error) {
        console.error('Azure AD error:', tokenResponse.error_description);
        return res.status(401).json({ error: 'Azure AD authentication failed' });
      }

      const payload = JSON.parse(Buffer.from(tokenResponse.id_token.split('.')[1], 'base64url').toString());
      const username = payload.name || payload.preferred_username || 'Azure User';
      const email = payload.preferred_username || payload.email || '';

      const ourToken = jwt.sign(
        { username, email, azureAD: true },
        JWT_SECRET,
        { expiresIn: '1h' }
      );

      res.json({ token: ourToken, username, email });

    } catch (err) {
      console.error('Azure auth error:', err.message);
      res.status(500).json({ error: 'Internal server error' });
    }
  });

  // ── TLS setup ─────────────────────────────────────────────────────────
  if (!fs.existsSync(certKeyPath) || !fs.existsSync(certFilePath)) {
    console.error(`TLS cert files not found.`);
    console.error(`  Key:  ${certKeyPath}`);
    console.error(`  Cert: ${certFilePath}`);
    console.error('Run win-acme first, then restart.');
    process.exit(1);
  }

  const tlsOptions = {
    key:  fs.readFileSync(certKeyPath),
    cert: fs.readFileSync(certFilePath),
  };

  // HTTP → HTTPS redirect
  http.createServer((req, res) => {
    res.writeHead(301, { Location: `https://${DOMAIN}${req.url}` });
    res.end();
  }).listen(80, '0.0.0.0', () => {
    console.log('HTTP :80 → redirecting to HTTPS');
  });

  https.createServer(tlsOptions, app).listen(443, '0.0.0.0', () => {
    console.log(`✅ Server running at https://${DOMAIN}`);
  });
}

startServer().catch(err => {
  console.error("Failed to start server:", err);
  process.exit(1);
});