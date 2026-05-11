const express = require('express');
const cors = require('cors');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const fs = require('fs');
const path = require('path');
const https = require('https');
const { DefaultAzureCredential } = require('@azure/identity');
const { SecretClient } = require('@azure/keyvault-secrets');

const app = express();
app.use(cors());
app.use(express.json());

const keyVaultUrl = "https://lume-bank-vault.vault.azure.net";
const credential = new DefaultAzureCredential();
const secretClient = new SecretClient(keyVaultUrl, credential);

const USERS_FILE = path.join(__dirname, 'users.json');

function loadUsers() {
  if (!fs.existsSync(USERS_FILE)) {
    fs.writeFileSync(USERS_FILE, JSON.stringify([]));
  }
  return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
}

function saveUsers(users) {
  fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2));
}

app.get('/api/health', (req, res) => {
  res.json({ status: 'online', keyVault: 'connected', azureAD: 'enabled' });
});

async function startServer() {
  // Load all secrets from Azure Key Vault using Managed Identity
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

  console.log("Secrets loaded from Azure Key Vault");

  app.post('/api/register', async (req, res) => {
    const { firstName, lastName, email, password, phone, dob, address, accountType } = req.body;

    if (!firstName || !password || !email) {
      return res.status(400).json({ success: false, message: 'First name, email and password are required' });
    }

    const users = loadUsers();
    const existing = users.find(u => u.email === email);

    if (existing) {
      return res.status(409).json({ success: false, message: 'An account with this email already exists' });
    }

    const hashedPassword = await bcrypt.hash(password, 10);

    const newUser = {
      id: Date.now(),
      firstName, lastName, email, phone, dob, address, accountType,
      password: hashedPassword
    };

    users.push(newUser);
    saveUsers(users);

    const token = jwt.sign(
      { id: newUser.id, email, firstName, lastName },
      JWT_SECRET,
      { expiresIn: '1h' }
    );

    res.json({ success: true, token, user: { firstName, lastName, email } });
  });

  app.post('/api/login', async (req, res) => {
    const { username, password } = req.body;

    if (!username || !password) {
      return res.status(400).json({ error: 'Email and password required' });
    }

    const users = loadUsers();
    const user = users.find(u =>
      u.email === username ||
      (u.firstName && u.firstName.toLowerCase() === username.toLowerCase())
    );

    if (!user) return res.status(401).json({ error: 'Invalid credentials' });

    const valid = await bcrypt.compare(password, user.password);
    if (!valid) return res.status(401).json({ error: 'Invalid credentials' });

    const token = jwt.sign(
      { id: user.id, email: user.email, firstName: user.firstName, lastName: user.lastName },
      JWT_SECRET,
      { expiresIn: '1h' }
    );

    res.json({
      success: true, token,
      username: user.firstName,
      user: { firstName: user.firstName, lastName: user.lastName, email: user.email }
    });
  });

  app.post('/api/auth/azure', async (req, res) => {
    const { code } = req.body;

    if (!code) return res.status(400).json({ error: 'Authorization code required' });

    try {
      const tokenRequestBody = new URLSearchParams({
        client_id: CLIENT_ID,
        client_secret: AD_CLIENT_SECRET,
        code: code,
        redirect_uri: AZURE_REDIRECT_URI,
        grant_type: 'authorization_code'
      });

      const tokenResponse = await new Promise((resolve, reject) => {
        const postData = tokenRequestBody.toString();
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
          response.on('end', () => resolve(JSON.parse(data)));
        });

        request.on('error', reject);
        request.write(postData);
        request.end();
      });

      if (tokenResponse.error) {
        return res.status(401).json({ error: 'Azure AD authentication failed' });
      }

      const idToken = tokenResponse.id_token;
      const payload = JSON.parse(Buffer.from(idToken.split('.')[1], 'base64').toString());

      const username = payload.name || payload.preferred_username || 'Azure User';
      const email = payload.preferred_username || payload.email || '';

      const ourToken = jwt.sign(
        { username, email, azureAD: true },
        JWT_SECRET,
        { expiresIn: '1h' }
      );

      res.json({ token: ourToken, username, email });

    } catch (err) {
      res.status(500).json({ error: 'Internal server error' });
    }
  });

  const PORT = process.env.PORT || 3000;
  app.listen(PORT, '127.0.0.1', () => {
    console.log(`Server running securely on localhost:${PORT}`);
  });
}

startServer().catch(err => {
  console.error("Failed to start server:", err);
  process.exit(1);
});