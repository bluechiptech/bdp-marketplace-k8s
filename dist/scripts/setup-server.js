#!/usr/bin/env node
/**
 * BDP Server Setup Script
 *
 * Run on the server: node setup-server.js
 *
 * Sets up:
 *   1. PostgreSQL databases (all 18 BDP service databases)
 *   2. Keycloak realm, client, roles, and test user
 */

const { execSync } = require("child_process");
const http = require("http");
const https = require("https");

// ── Config ──────────────────────────────────────────────────────────────
const PG_HOST = process.env.POSTGRES_HOST || "localhost";
const PG_PORT = process.env.POSTGRES_PORT || "5432";
const PG_USER = process.env.POSTGRES_USER || "postgres";
const PG_PASS = process.env.POSTGRES_PASSWORD || "postgres";

const KC_BASE = process.env.KEYCLOAK_URL || "http://localhost:8080";
const KC_ADMIN = process.env.KEYCLOAK_ADMIN || "admin";
const KC_PASS = process.env.KEYCLOAK_ADMIN_PASSWORD || "admin";
const KC_REALM = "bdp";
const KC_CLIENT_ID = "bdp-ui";
// SERVER_IP is the BROWSER-FACING IP/host of this server. It is NOT derivable
// on the host (the private NIC address differs from the public IP the browser
// uses), so it must be supplied explicitly. A wrong/guessed value would rewrite
// every Keycloak redirect URI and break all logins — so refuse to continue
// rather than fall back to a stale hardcoded IP.
const SERVER_IP = process.env.SERVER_IP;
if (!SERVER_IP) {
  console.error(
    "\x1b[31m  ✗\x1b[0m SERVER_IP is required (the browser-facing IP/host of " +
    "this server).\n    Re-run as: SERVER_IP=<public-ip> node setup-server.js\n" +
    "    Refusing to continue — a wrong IP would rewrite Keycloak redirect " +
    "URIs and break every user's login."
  );
  process.exit(1);
}
// Browser-facing origin of the BDP UI, used for the bdp-ui client's redirect
// URIs and web origins. Defaults to http://<SERVER_IP>:3000 (plain-HTTP/IP
// deploy); first-boot passes an https://<domain> origin when TLS is enabled.
const UI_ORIGIN = process.env.UI_ORIGIN || `http://${SERVER_IP}:3000`;

const DATABASES = [
  "bdp_auth", "bdp_catalog", "bdp_security", "bdp_sql", "bdp_domain",
  "bdp_backup", "bdp_config", "bdp_metering", "bdp_license", "bdp_update",
  "bdp_keymanager", "bdp_notification", "bdp_pipeline", "bdp_storage",
  "bdp_cloud", "bdp_cluster_registry", "bdp_registry", "bdp_service",
];

const BDP_ROLES = [
  "admin", "operator", "data-engineer", "pipeline-dev", "data-analyst", "viewer",
];

// ── Helpers ─────────────────────────────────────────────────────────────
function log(msg) { console.log(`\x1b[36m[BDP]\x1b[0m ${msg}`); }
function ok(msg)  { console.log(`\x1b[32m  ✓\x1b[0m ${msg}`); }
function warn(msg){ console.log(`\x1b[33m  ⚠\x1b[0m ${msg}`); }
function fail(msg){ console.log(`\x1b[31m  ✗\x1b[0m ${msg}`); }

function httpRequest(url, options = {}, body = null) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith("https") ? https : http;
    const req = mod.request(url, options, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, body: data }));
    });
    req.on("error", reject);
    if (body) req.write(typeof body === "string" ? body : JSON.stringify(body));
    req.end();
  });
}

async function kcPost(path, token, payload) {
  const url = `${KC_BASE}${path}`;
  return httpRequest(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
  }, JSON.stringify(payload));
}

async function kcPut(path, token, payload) {
  const url = `${KC_BASE}${path}`;
  return httpRequest(url, {
    method: "PUT",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
  }, JSON.stringify(payload));
}

async function kcGet(path, token) {
  const url = `${KC_BASE}${path}`;
  return httpRequest(url, {
    method: "GET",
    headers: { Authorization: `Bearer ${token}` },
  });
}

// Set a user's password via a DEDICATED reset-password call, and clear any
// required actions. Some Keycloak builds silently ignore a password supplied
// inline in the POST /users create body, which leaves the user existing but
// unable to log in ("Invalid user credentials"). Setting it explicitly here
// works across all Keycloak versions. (Verified on a fresh AKS 2026-07-25.)
async function setUserPassword(token, username, password) {
  const listRes = await kcGet(
    `/admin/realms/${KC_REALM}/users?username=${encodeURIComponent(username)}&exact=true`,
    token
  );
  let user = null;
  try { user = JSON.parse(listRes.body)[0]; } catch { /* fallthrough */ }
  if (!user || !user.id) { warn(`Could not find user '${username}' to set password`); return; }
  await kcPut(`/admin/realms/${KC_REALM}/users/${user.id}`, token, {
    enabled: true,
    requiredActions: [],
  });
  const res = await kcPut(
    `/admin/realms/${KC_REALM}/users/${user.id}/reset-password`,
    token,
    { type: "password", value: password, temporary: false }
  );
  if (res.status === 204) ok(`Password set for '${username}'`);
  else warn(`reset-password for '${username}': ${res.status} ${res.body}`);
}

// ── 1. PostgreSQL ───────────────────────────────────────────────────────
function setupDatabases() {
  log("Setting up PostgreSQL databases...");
  const env = { ...process.env, PGPASSWORD: PG_PASS };
  const psql = `psql -h ${PG_HOST} -p ${PG_PORT} -U ${PG_USER}`;

  try {
    execSync(`${psql} -c "SELECT 1"`, { env, stdio: "pipe" });
    ok("PostgreSQL is reachable");
  } catch {
    fail("Cannot connect to PostgreSQL — is it running?");
    return false;
  }

  for (const db of DATABASES) {
    try {
      const exists = execSync(
        `${psql} -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'"`,
        { env, stdio: "pipe" }
      ).toString().trim();

      if (exists === "1") {
        ok(`${db} (exists)`);
      } else {
        execSync(`${psql} -c "CREATE USER ${db} WITH PASSWORD '${db}';"`, { env, stdio: "pipe" }).toString();
        execSync(`${psql} -c "CREATE DATABASE ${db} OWNER ${db};"`, { env, stdio: "pipe" });
        execSync(`${psql} -d ${db} -c "GRANT ALL ON SCHEMA public TO ${db};"`, { env, stdio: "pipe" });
        ok(`${db} (created)`);
      }
    } catch (e) {
      // user might already exist
      try {
        execSync(`${psql} -c "CREATE DATABASE ${db};"`, { env, stdio: "pipe" });
        ok(`${db} (created, user may already exist)`);
      } catch {
        ok(`${db} (already exists)`);
      }
    }
  }
  return true;
}

// ── 2. Keycloak ─────────────────────────────────────────────────────────
async function waitForKeycloak(maxWait = 60) {
  log(`Waiting for Keycloak at ${KC_BASE}...`);
  const start = Date.now();
  while (Date.now() - start < maxWait * 1000) {
    try {
      const res = await httpRequest(`${KC_BASE}/realms/master`, { method: "GET" });
      if (res.status === 200) { ok("Keycloak is ready"); return true; }
    } catch {}
    await new Promise((r) => setTimeout(r, 2000));
  }
  fail(`Keycloak not ready after ${maxWait}s`);
  return false;
}

async function getAdminToken() {
  const body = new URLSearchParams({
    grant_type: "password",
    client_id: "admin-cli",
    username: KC_ADMIN,
    password: KC_PASS,
  }).toString();

  const res = await httpRequest(
    `${KC_BASE}/realms/master/protocol/openid-connect/token`,
    { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" } },
    body
  );

  if (res.status !== 200) {
    fail(`Failed to get admin token: ${res.status} ${res.body}`);
    return null;
  }
  const token = JSON.parse(res.body).access_token;
  ok("Got admin token");
  return token;
}

// Create a client, or — when it already exists — update it in place so that
// redirect URIs / secrets track SERVER_IP across re-runs and server moves.
async function upsertClient(token, config) {
  const createRes = await kcPost(`/admin/realms/${KC_REALM}/clients`, token, config);
  if (createRes.status === 201) return "created";
  if (createRes.status !== 409) return `error ${createRes.status}: ${createRes.body}`;

  const listRes = await kcGet(
    `/admin/realms/${KC_REALM}/clients?clientId=${encodeURIComponent(config.clientId)}`,
    token
  );
  if (listRes.status !== 200) return `lookup failed: ${listRes.status}`;
  const existing = JSON.parse(listRes.body)[0];
  if (!existing) return "lookup failed: not found after 409";

  const updateRes = await kcPut(
    `/admin/realms/${KC_REALM}/clients/${existing.id}`,
    token,
    { ...config, id: existing.id }
  );
  return updateRes.status === 204 ? "updated" : `update failed: ${updateRes.status}`;
}

async function setupKeycloak() {
  log("Setting up Keycloak...");
  if (!(await waitForKeycloak())) return false;

  const token = await getAdminToken();
  if (!token) return false;

  // Create realm
  const realmRes = await kcPost("/admin/realms", token, {
    realm: KC_REALM,
    enabled: true,
    registrationAllowed: true,
    loginWithEmailAllowed: true,
    duplicateEmailsAllowed: false,
    resetPasswordAllowed: true,
    editUsernameAllowed: false,
    bruteForceProtected: true,
  });
  if (realmRes.status === 201) {
    ok(`Realm '${KC_REALM}' created`);
  } else if (realmRes.status === 409) {
    ok(`Realm '${KC_REALM}' already exists`);
  } else {
    fail(`Realm creation: ${realmRes.status} ${realmRes.body}`);
  }

  // Disable SSL requirement for bdp realm (allows HTTP from external IPs)
  const sslRes = await kcPut(`/admin/realms/${KC_REALM}`, token, {
    sslRequired: "none",
  });
  if (sslRes.status === 204) {
    ok("SSL requirement disabled for bdp realm");
  } else {
    warn(`SSL disable: ${sslRes.status}`);
  }

  // Also disable SSL for master realm
  const masterSslRes = await kcPut("/admin/realms/master", token, {
    sslRequired: "none",
  });
  if (masterSslRes.status === 204) {
    ok("SSL requirement disabled for master realm");
  } else {
    warn(`Master SSL disable: ${masterSslRes.status}`);
  }

  // Create/refresh public client (bdp-ui) — upserted so redirect URIs follow
  // SERVER_IP when the platform is redeployed on a different host.
  const uiResult = await upsertClient(token, {
    clientId: KC_CLIENT_ID,
    publicClient: true,
    enabled: true,
    directAccessGrantsEnabled: true,
    standardFlowEnabled: true,
    implicitFlowEnabled: false,
    redirectUris: [
      `${UI_ORIGIN}/*`,
      "http://localhost:3000/*",
    ],
    webOrigins: [
      UI_ORIGIN,
      "http://localhost:3000",
      "+",
    ],
    attributes: {
      "pkce.code.challenge.method": "S256",
    },
  });
  if (uiResult === "created" || uiResult === "updated") {
    ok(`Client '${KC_CLIENT_ID}' ${uiResult}`);
  } else {
    fail(`Client '${KC_CLIENT_ID}': ${uiResult}`);
  }

  // Create/refresh service-account client (bdp-platform) for backend services
  const svcResult = await upsertClient(token, {
    clientId: "bdp-platform",
    publicClient: false,
    enabled: true,
    secret: "bdp-platform-secret",
    serviceAccountsEnabled: true,
    directAccessGrantsEnabled: true,
    standardFlowEnabled: false,
  });
  if (svcResult === "created" || svcResult === "updated") {
    ok(`Client 'bdp-platform' (service account) ${svcResult}`);
  } else {
    warn(`Service client: ${svcResult}`);
  }

  // ── Tool OIDC clients (SSO for installed data tools) ──────────────────
  // Secrets default to bdp-<tool>-secret but are overridable per client via an
  // env var (BDP_<TOOL>_CLIENT_SECRET) so production can inject strong, rotated
  // secrets without code changes. The SAME value must be given to
  // bdp-service-manager (bdp.keycloak.tool-secrets.<tool>) so the injected
  // chart OIDC config matches what Keycloak expects.
  const toolSecret = (tool, fallback) =>
    process.env[`BDP_${tool.toUpperCase().replace(/-/g, "_")}_CLIENT_SECRET`] || fallback;
  const TOOL_CLIENTS = [
    { clientId: "bdp-nifi",       key: "nifi",       secret: "bdp-nifi-secret",       name: "NiFi" },
    { clientId: "bdp-airflow",    key: "airflow",    secret: "bdp-airflow-secret",    name: "Airflow" },
    { clientId: "bdp-superset",   key: "superset",   secret: "bdp-superset-secret",   name: "Superset" },
    { clientId: "bdp-minio",      key: "minio",      secret: "bdp-minio-secret",      name: "MinIO" },
    { clientId: "bdp-kafka-ui",   key: "kafka-ui",   secret: "bdp-kafka-ui-secret",   name: "Kafka UI" },
    { clientId: "bdp-jupyterhub", key: "jupyterhub", secret: "bdp-jupyterhub-secret", name: "JupyterHub" },
    { clientId: "bdp-mlflow",     key: "mlflow",     secret: "bdp-mlflow-secret",     name: "MLflow" },
  ];

  // Scope redirects to THIS server's host rather than the wildcard "*" (which
  // is an open redirect), covering both deployment models:
  //   VM offer  — tools served at http(s)://<host>:<nodePort>/...  (host:port)
  //   K8s offer — tools served at https://<tool>.<host>/...        (subdomain)
  // Keycloak accepts a subdomain wildcard, verified to store as-is.
  const toolRedirectUris = [
    `http://${SERVER_IP}:*`,
    `https://${SERVER_IP}:*`,
    `https://*.${SERVER_IP}/*`,
  ];

  for (const tc of TOOL_CLIENTS) {
    const tcResult = await upsertClient(token, {
      clientId: tc.clientId,
      name: tc.name,
      publicClient: false,
      enabled: true,
      secret: toolSecret(tc.key, tc.secret),
      standardFlowEnabled: true,
      directAccessGrantsEnabled: true,
      serviceAccountsEnabled: false,
      redirectUris: toolRedirectUris,
      webOrigins: ["+"],
    });
    if (tcResult === "created" || tcResult === "updated") {
      ok(`Client '${tc.clientId}' (${tc.name} OIDC) ${tcResult}`);
    } else {
      warn(`Client '${tc.clientId}': ${tcResult}`);
    }
  }

  // ── Grafana OIDC client (Task E3: same-origin Grafana behind the gateway) ─
  // Unlike TOOL_CLIENTS above, Grafana is served same-origin under this
  // server's own domain (https://<host>/grafana, via the gateway's
  // Path=/grafana/** route — see bdp-gateway/application.yml), not a
  // per-tool subdomain/port, so it gets one exact redirect path rather than
  // the wildcard host:port/subdomain patterns those tools need. client_id is
  // "grafana" (not "bdp-<tool>") and the secret must match
  // grafanaOAuth.clientSecret in bdp-marketplace-k8s/charts/bdp/values.yaml
  // (the bdp-grafana-oauth Secret Grafana reads GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
  // from). role_attribute_path in that same OIDC config reads
  // realm_access.roles directly against the 'admin' realm role created below
  // — no separate client role mapping needed.
  const grafanaSecret = process.env.BDP_GRAFANA_CLIENT_SECRET || "bdp-grafana-secret";
  const grafanaResult = await upsertClient(token, {
    clientId: "grafana",
    name: "Grafana",
    publicClient: false,
    enabled: true,
    secret: grafanaSecret,
    standardFlowEnabled: true,
    directAccessGrantsEnabled: false,
    serviceAccountsEnabled: false,
    redirectUris: [
      `http://${SERVER_IP}/grafana/login/generic_oauth`,
      `https://${SERVER_IP}/grafana/login/generic_oauth`,
    ],
    webOrigins: ["+"],
  });
  if (grafanaResult === "created" || grafanaResult === "updated") {
    ok(`Client 'grafana' (Grafana OIDC) ${grafanaResult}`);
  } else {
    warn(`Client 'grafana': ${grafanaResult}`);
  }

  // Add MinIO policy mapper (maps all OIDC users to consoleAdmin policy)
  const minioListRes = await kcGet(
    `/admin/realms/${KC_REALM}/clients?clientId=bdp-minio`,
    token
  );
  if (minioListRes.status === 200) {
    const minioClients = JSON.parse(minioListRes.body);
    if (minioClients.length > 0) {
      const mapperRes = await kcPost(
        `/admin/realms/${KC_REALM}/clients/${minioClients[0].id}/protocol-mappers/models`,
        token,
        {
          name: "minio-policy",
          protocol: "openid-connect",
          protocolMapper: "oidc-hardcoded-claim-mapper",
          config: {
            "claim.name": "policy",
            "claim.value": "consoleAdmin",
            "jsonType.label": "String",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "userinfo.token.claim": "true",
          },
        }
      );
      if (mapperRes.status === 201) ok("MinIO policy mapper added");
      else if (mapperRes.status === 409) ok("MinIO policy mapper exists");
    }
  }

  // Create realm roles
  for (const role of BDP_ROLES) {
    const roleRes = await kcPost(`/admin/realms/${KC_REALM}/roles`, token, {
      name: role,
      description: `BDP ${role.replace("bdp-", "")} role`,
    });
    if (roleRes.status === 201) ok(`Role '${role}' created`);
    else if (roleRes.status === 409) ok(`Role '${role}' exists`);
    else warn(`Role '${role}': ${roleRes.status}`);
  }

  // Helper: assign all BDP roles to a user by username
  async function assignRoles(username) {
    const listRes = await kcGet(
      `/admin/realms/${KC_REALM}/users?username=${username}&exact=true`,
      token
    );
    if (listRes.status !== 200) return;
    const users = JSON.parse(listRes.body);
    if (users.length === 0) return;
    const userId = users[0].id;
    for (const roleName of BDP_ROLES) {
      const roleGetRes = await kcGet(
        `/admin/realms/${KC_REALM}/roles/${roleName}`,
        token
      );
      if (roleGetRes.status === 200) {
        const roleObj = JSON.parse(roleGetRes.body);
        await kcPost(
          `/admin/realms/${KC_REALM}/users/${userId}/role-mappings/realm`,
          token,
          [roleObj]
        );
      }
    }
    ok(`Assigned all BDP roles to '${username}'`);
  }

  // Create test user: engineer / engineer
  const userRes = await kcPost(`/admin/realms/${KC_REALM}/users`, token, {
    username: "engineer",
    enabled: true,
    emailVerified: true,
    email: "engineer@bdp.local",
    firstName: "BDP",
    lastName: "Engineer",
    credentials: [{ type: "password", value: "engineer", temporary: false }],
  });
  if (userRes.status === 201) {
    ok("User 'engineer' created (password: engineer)");
    // Only on creation: some Keycloak builds ignore credentials in the
    // create body, so assert the password once. An EXISTING user's
    // password is never touched — re-runs must be credential-neutral,
    // or every upgrade resets live passwords to the known default.
    await setUserPassword(token, "engineer", "engineer");
  } else if (userRes.status === 409) {
    ok("User 'engineer' already exists (password left unchanged)");
  } else {
    fail(`User creation: ${userRes.status} ${userRes.body}`);
  }
  await assignRoles("engineer");

  // Create admin user: admin / admin
  const adminRes = await kcPost(`/admin/realms/${KC_REALM}/users`, token, {
    username: "admin",
    enabled: true,
    emailVerified: true,
    email: "admin@bdp.local",
    firstName: "BDP",
    lastName: "Admin",
    credentials: [{ type: "password", value: "admin", temporary: false }],
  });
  if (adminRes.status === 201) {
    ok("User 'admin' created (password: admin)");
    await setUserPassword(token, "admin", "admin");
  } else if (adminRes.status === 409) {
    ok("User 'admin' already exists (password left unchanged)");
  }
  await assignRoles("admin");

  return true;
}

// ── Main ────────────────────────────────────────────────────────────────
async function main() {
  console.log("\n╔══════════════════════════════════════╗");
  console.log("║      BDP Server Setup Script         ║");
  console.log("╚══════════════════════════════════════╝\n");

  log(`Server IP: ${SERVER_IP}`);
  log(`PostgreSQL: ${PG_HOST}:${PG_PORT}`);
  log(`Keycloak: ${KC_BASE}\n`);

  const pgOk = setupDatabases();
  console.log();

  const kcOk = await setupKeycloak();
  console.log();

  // Summary
  console.log("══════════════════════════════════════");
  log("Summary:");
  if (pgOk) ok(`${DATABASES.length} databases ready`);
  else fail("PostgreSQL setup had issues");
  if (kcOk) {
    ok("Keycloak realm 'bdp' ready");
    ok("Client 'bdp-ui' ready");
    ok("Tool OIDC clients: nifi, airflow, superset, minio, kafka-ui, jupyterhub, mlflow");
    ok("Client 'grafana' ready (same-origin SSO behind the gateway)");
    ok("Users: engineer/engineer, admin/admin");
    console.log();
    log("Keycloak admin console:");
    console.log(`  ${KC_BASE}/admin/master/console/`);
    log("OIDC discovery:");
    console.log(`  ${KC_BASE}/realms/bdp/.well-known/openid-configuration`);
  } else {
    fail("Keycloak setup had issues");
  }
  console.log("══════════════════════════════════════\n");
}

main().catch((e) => { fail(e.message); process.exit(1); });
