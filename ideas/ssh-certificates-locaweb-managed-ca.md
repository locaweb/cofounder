# Alternate Scenario: Locaweb-Managed SSH Certificate Authority

What if Locaweb operated a centralized step-ca server as a platform service
for all Locaweb Cloud customers?

Date: 2025-04-02

---

## 1. The Vision

Locaweb runs a single step-ca instance (or HA cluster) as a managed platform
service. Every VM provisioned on Locaweb Cloud **automatically trusts this CA**.
Customers never generate, store, or manage SSH keys at all. Instead:

- Developers authenticate via their GitHub identity
- GitHub Actions authenticate via OIDC tokens
- Both receive short-lived SSH certificates signed by Locaweb's CA
- VMs accept any certificate signed by the Locaweb CA, subject to principal matching

```
 ┌─────────────────────────────────────────────────────────────────┐
 │                     Locaweb Cloud Platform                      │
 │                                                                 │
 │  ┌──────────────────┐     ┌──────────────────────────────────┐  │
 │  │   step-ca (HA)   │     │  CloudStack VM Templates         │  │
 │  │                  │     │  ┌────────────────────────────┐  │  │
 │  │  OIDC Provsnrs:  │     │  │ /etc/ssh/sshd_config:      │  │  │
 │  │  - GH Actions    │     │  │   TrustedUserCAKeys ...    │  │  │
 │  │  - GH OAuth      │     │  │   AuthorizedPrincipalsFile │  │  │
 │  │                  │     │  │                            │  │  │
 │  │  SSH Templates:  │     │  │ /etc/ssh/ssh_user_ca.pub:  │  │  │
 │  │  - per-customer  │     │  │   (Locaweb CA public key)  │  │  │
 │  │    scoping       │     │  └────────────────────────────┘  │  │
 │  └──────────────────┘     └──────────────────────────────────┘  │
 │           ▲   ▲                          ▲                      │
 └───────────┼───┼──────────────────────────┼──────────────────────┘
             │   │                          │
             │   │                   All VMs trust
             │   │                   Locaweb CA at
             │   │                   boot (baked into
             │   │                   template image)
             │   │
   ┌─────────┘   └──────────┐
   │                        │
 Developer               GitHub Actions
 (step ssh login)        (OIDC token exchange)
   │                        │
 GitHub OAuth            GitHub OIDC
 (browser flow)          (automatic)
```

---

## 2. What Locaweb Builds

### 2.1 The step-ca Service

A centralized step-ca deployment, likely:
- 2+ instances behind a load balancer for HA
- CA private key in an HSM or cloud KMS (never on disk)
- Accessible at e.g. `ssh-ca.locaweb.com.br`
- Database-backed provisioner storage (not file-based `ca.json`)

### 2.2 Two OIDC Provisioners

**Provisioner 1: GitHub Actions** (for CI/CD pipelines)

```json
{
  "type": "OIDC",
  "name": "github-actions",
  "clientID": "api://LocawebSSHCA",
  "clientSecret": "",
  "configurationEndpoint": "https://token.actions.githubusercontent.com/.well-known/openid-configuration",
  "claims": {
    "enableSSHCA": true,
    "defaultUserSSHCertDuration": "1h",
    "maxUserSSHCertDuration": "2h"
  },
  "options": {
    "ssh": {
      "template": "{{ SSH template that extracts repo from .Token.repository }}"
    }
  }
}
```

The key insight from step-ca source code: the `.Token` variable in SSH templates
gives access to **all JWT claims** from the GitHub OIDC token. This includes:
- `.Token.repository` → `"gmautner/my-app"`
- `.Token.repository_owner` → `"gmautner"`
- `.Token.actor` → `"gmautner"`
- `.Token.job_workflow_ref` → full workflow path
- `.Token.sub` → `"repo:gmautner/my-app:ref:refs/heads/main"`

**Provisioner 2: GitHub OAuth** (for human developers)

```json
{
  "type": "OIDC",
  "name": "github-oauth",
  "clientID": "<locaweb-github-app-client-id>",
  "clientSecret": "<locaweb-github-app-client-secret>",
  "configurationEndpoint": "https://token.actions.githubusercontent.com/.well-known/openid-configuration",
  "scopes": ["read:org", "read:user"],
  "claims": {
    "enableSSHCA": true,
    "defaultUserSSHCertDuration": "8h",
    "maxUserSSHCertDuration": "16h"
  },
  "options": {
    "ssh": {
      "template": "{{ SSH template that maps GitHub username to principals }}"
    }
  }
}
```

Note: GitHub's OIDC for OAuth Apps uses a different discovery endpoint than
GitHub Actions. Locaweb would register a GitHub App (or OAuth App) and use it
as the OIDC provider for human authentication.

### 2.3 SSH Certificate Template (Tenant-Scoped)

This is where multi-tenancy lives. A custom SSH template controls what
principals are placed in the certificate:

```json
{
  "type": {{ toJson .Type }},
  "keyId": "{{ .Token.repository }}:{{ .Token.actor }}:run-{{ .Token.run_id }}",
  "principals": ["root"],
  "extensions": {{ toJson .Extensions }},
  "criticalOptions": {
    "source-address": "{{ customer's VM IP ranges }}"
  }
}
```

For human users, the template would use the GitHub username:

```json
{
  "type": "user",
  "keyId": {{ toJson .Token.sub }},
  "principals": [{{ toJson .Token.preferred_username }}, "root"],
  "extensions": {{ toJson .Extensions }}
}
```

The `principals` field is what the VM checks against `AuthorizedPrincipalsFile`.
This is where **tenant isolation happens**: even though the CA signs certs for
all customers, each VM only accepts certs with matching principals.

### 2.4 CloudStack VM Template Changes

This is the biggest win of the Locaweb-managed approach. Instead of each
customer configuring `TrustedUserCAKeys` via cloud-init, **Locaweb bakes it
into the base VM template image**:

```bash
# In the golden image used for all Locaweb Cloud VMs:

# /etc/ssh/ssh_user_ca_key.pub
ssh-ed25519 AAAA... locaweb-ssh-ca

# /etc/ssh/sshd_config (appended)
TrustedUserCAKeys /etc/ssh/ssh_user_ca_key.pub
AuthorizedPrincipalsFile /etc/ssh/authorized_principals

# /etc/ssh/authorized_principals
root
```

This means: **every VM provisioned on Locaweb Cloud trusts the CA out of the
box, with zero customer configuration.** The `authorized_principals` file
can be customized per-VM via cloud-init userdata at deploy time.

### 2.5 Customer Onboarding API

Locaweb exposes an API (or CloudStack plugin) for customers to:

1. **Register their GitHub org/repo** — tells the CA which repos can get certs
2. **List authorized GitHub usernames** — maps to SSH principals on their VMs
3. **Configure per-environment access** — e.g., only `main` branch deploys to production VMs

This could be a simple REST API, a CloudStack plugin, or even a self-service
portal integrated into the Locaweb Cloud console.

---

## 3. What Changes for Cofounder / Customer Side

### 3.1 Provisioning (`locaweb-cloud-provision`)

| Component | Before | After |
|-----------|--------|-------|
| SSH keypair in CloudStack | Created per network, registered via API | **Removed entirely** |
| `SSH_PRIVATE_KEY` GitHub secret | Required per repo per env | **Removed entirely** |
| `provision_infrastructure.py` keypair code | ~30 lines creating/registering keypairs | **Deleted** |
| Cloud-init userdata SSH setup | Not needed (CloudStack injects key) | Not needed (baked into template) |
| `rotate_ssh_key.py` | 300+ lines, stops/restarts all VMs | **Deleted entirely** |
| `rotate-ssh-key.yml` workflow | Reusable workflow | **Deleted entirely** |

### 3.2 Deployment Workflows

```yaml
# Before (current):
secrets:
  SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
# ... later:
- uses: webfactory/ssh-agent@v0.9.0
  with:
    ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

# After (Locaweb-managed CA):
permissions:
  id-token: write  # Required for GitHub OIDC
# ... later:
- name: Get SSH certificate from Locaweb CA
  run: |
    # Get GitHub OIDC token
    OIDC_TOKEN=$(curl -s \
      -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://LocawebSSHCA")

    # Generate ephemeral key pair
    ssh-keygen -t ed25519 -f /tmp/deploy_key -N "" -q

    # Exchange OIDC token for SSH certificate via Locaweb's step-ca
    step ca ssh certificate \
      --ca-url https://ssh-ca.locaweb.com.br \
      --provisioner github-actions \
      --token "$OIDC_TOKEN" \
      --principal root \
      --not-after 1h \
      "deploy-$GITHUB_REPOSITORY" \
      /tmp/deploy_key.pub

    # Load into agent
    eval $(ssh-agent -s)
    echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" >> $GITHUB_ENV
    echo "SSH_AGENT_PID=$SSH_AGENT_PID" >> $GITHUB_ENV
    ssh-add /tmp/deploy_key
```

**Key difference from self-managed CA:** No `SSH_CA_PRIVATE_KEY` secret at all.
The CA private key never leaves Locaweb's infrastructure. The workflow just
exchanges a GitHub OIDC token for a signed certificate.

### 3.3 Local Developer Access

```bash
# One-time bootstrap (installs Locaweb CA trust):
step ca bootstrap --ca-url https://ssh-ca.locaweb.com.br \
  --fingerprint <locaweb-ca-fingerprint>

# Each session (opens browser → GitHub OAuth → cert in agent):
step ssh login --provisioner github-oauth
# Certificate valid for 8 hours, stored in ssh-agent (not on disk)

# SSH works transparently:
ssh root@<vm-ip>
```

No `-i ~/.ssh/<repo-name>` flag. No key files on disk. Works from any computer
after the one-time bootstrap.

### 3.4 Team Management

```bash
# Owner registers team members via Locaweb API or portal:
locaweb ssh authorize --repo gmautner/my-app --github-user teammate1
locaweb ssh authorize --repo gmautner/my-app --github-user teammate2

# This updates the authorized_principals on the VMs or configures
# the CA's SSH template to include these usernames as valid principals.

# Team member simply runs:
step ssh login --provisioner github-oauth
ssh root@<vm-ip>   # works if their GitHub username is authorized
```

### 3.5 Cofounder Plugin Changes

| Component | Before | After |
|-----------|--------|-------|
| `skills/app-deploy/SKILL.md` Step 3 | Generate SSH key, upload to GitHub | **Remove step entirely** — no SSH setup needed |
| `skills/app-deploy/references/workflows.md` | `webfactory/ssh-agent` + `SSH_PRIVATE_KEY` | OIDC token exchange + `step ca ssh certificate` |
| `skills/ssh-key-rotation/` | Full skill with 7-step procedure | **Delete entire skill** |
| `skills/app-deploy/references/operations.md` | SSH with `-i ~/.ssh/<repo-name>` | Just `ssh root@<ip>` (cert in agent) |
| Setup instructions | "Generate SSH key" | "Bootstrap Locaweb CA trust" (one-time) |

---

## 4. Multi-Tenancy Model

### 4.1 Where Tenant Isolation Lives

In this architecture, isolation is **not at the CA level** — the CA signs
certificates for all customers. Instead, isolation happens at **two layers**:

**Layer 1: Certificate issuance (step-ca)**

The SSH certificate template uses token claims to scope the certificate:

```
Certificate for GitHub Actions from repo "gmautner/my-app":
  KeyID: "gmautner/my-app:deploy:run-12345"
  Principals: ["root"]
  Valid: +1h
  CriticalOptions:
    source-address: "189.x.x.x"  (customer's VM public IP)
```

The `source-address` critical option is powerful — it restricts where the
certificate can be used from. For GitHub Actions, this would be limited to
the target VM's IP. For developers, this could be omitted or set to the
developer's current IP.

**Layer 2: VM-side principal matching (sshd)**

Each VM's `/etc/ssh/authorized_principals` lists which principals are allowed:

```
# VM belonging to customer "gmautner/my-app"
root
gmautner
teammate1
```

A certificate signed for user `attacker` (valid, from the same CA) would be
rejected because `attacker` is not in this VM's `authorized_principals`.

### 4.2 Why This Is Secure

Even though the CA is shared:

1. **Certificates can't impersonate**: A user authenticates as `gmautner` via
   GitHub OAuth. The CA issues a cert with principal `gmautner`. They can't
   get a cert with principal `teammate1` because the CA derives principals
   from the authenticated identity.

2. **VMs only accept authorized principals**: Customer A's VMs don't list
   Customer B's users in `authorized_principals`.

3. **GitHub Actions certs are scoped by repo**: The template can restrict based
   on `.Token.repository`. The CA only issues certs for the repo that the
   workflow belongs to.

4. **source-address further restricts**: Even if a cert leaks, it only works
   from specific IPs.

This is the same model used by Facebook, Netflix, and Uber — one CA, many
hosts, principal-based access control at the edge.

### 4.3 Risk: Compromised CA

If Locaweb's CA private key is compromised, **all customers' VMs are at risk**.
This is the single biggest concern with the shared model.

Mitigations:
- HSM-backed CA key (the key never exists in extractable form)
- The HSM performs signing operations; the key literally cannot be exported
- step-ca supports PKCS#11, AWS KMS, Google Cloud KMS, Azure Key Vault
- Regular CA key rotation (with overlap period where both old and new are trusted)
- Audit logging of all certificate issuance

---

## 5. Comparison: Self-Managed vs Locaweb-Managed

| Aspect | Self-Managed CA (original proposal) | Locaweb-Managed CA |
|--------|-------------------------------------|-------------------|
| **CA key management** | Customer stores CA key in GitHub secrets | Locaweb manages in HSM — customer never touches CA key |
| **VM trust setup** | Customer configures via cloud-init userdata | Pre-baked in VM template — zero config |
| **SSH key rotation** | Simplified (update secret + redeploy) | **Eliminated entirely** |
| **GitHub secrets needed** | `SSH_CA_PRIVATE_KEY` (one per org) | **None for SSH** |
| **Developer setup** | Self-hosted step-ca or workflow_dispatch hack | `step ca bootstrap` one-liner |
| **Team management** | Manual `authorized_principals` + cron sync | API/portal provided by Locaweb |
| **Operational burden** | Customer runs/monitors step-ca | Locaweb runs/monitors step-ca |
| **CA availability** | Customer's problem | Locaweb's SLA |
| **CA key security** | GitHub secrets (software) | HSM (hardware) |
| **Break-glass** | Customer maintains fallback key | Locaweb CloudStack console access |
| **Host certificates** | Customer deploys manually | Locaweb can sign host certs at provision time |
| **Implementation effort** | Moderate (cofounder + locaweb-cloud-provision changes) | Heavy for Locaweb, trivial for customer |
| **Dependency** | GitHub + self-managed CA | GitHub + Locaweb CA service |
| **Blast radius of CA compromise** | One customer's VMs | All Locaweb Cloud VMs |

---

## 6. Advantages of the Locaweb-Managed Approach

### 6.1 Massive Simplification for Customers

The entire SSH key lifecycle disappears from the customer's concern:

```
Current flow:
  1. Generate SSH key locally
  2. Upload public key to GitHub secrets
  3. Register keypair in CloudStack
  4. Deploy VM with keypair
  5. Store private key on disk for local access
  6. Rotate when changing computers (downtime!)
  7. Share key for team access (insecure!)

Locaweb-managed flow:
  1. (nothing — it just works)
```

For GitHub Actions: add `permissions: id-token: write` and a step-ca call.
For developers: one-time `step ca bootstrap`, then `step ssh login` per session.

### 6.2 Host Certificates for Free

Because Locaweb controls the CA and the provisioning pipeline, they can sign
**host certificates** at VM creation time:

```bash
# During VM provisioning (inside Locaweb's pipeline):
step ca ssh certificate \
  --host \
  --provisioner locaweb-internal \
  --principal "$VM_HOSTNAME,$VM_IP" \
  --not-after 720h \
  "$VM_HOSTNAME" /etc/ssh/ssh_host_ed25519_key.pub
```

This eliminates `StrictHostKeyChecking=no` — clients can verify hosts
cryptographically. No more MITM risk on first connection.

### 6.3 Audit Trail Across All Customers

Locaweb gets centralized certificate issuance logs:
- Who requested a certificate (GitHub identity)
- For which repository/workflow
- At what time, with what validity
- Which principals were granted

This is valuable for incident response and compliance.

### 6.4 Natural Integration with CloudStack

Locaweb could extend CloudStack to natively support certificate-based auth:
- VM deployment API no longer requires `keypair=` parameter
- `resetSSHKeyForVirtualMachine` API becomes unnecessary
- `authorized_principals` managed via CloudStack metadata or tags
- Custom CloudStack plugin for team member authorization

---

## 7. Challenges and Open Questions

### 7.1 Does GitHub OAuth Provide Sufficient OIDC for step-ca?

**Important distinction:** There are two separate authentication flows here:

1. **GitHub Actions OIDC (for CI/CD)** — This is fully proven and well-documented.
   The Smallstep blog post at smallstep.com/blog/github-actions-oidc-tls-credentials
   demonstrates exactly this: workflow requests JWT from `$ACTIONS_ID_TOKEN_REQUEST_URL`,
   step-ca validates it against GitHub's JWKS, issues a certificate. The provisioner
   config is straightforward, the token claims are rich (`repository`, `actor`,
   `job_workflow_ref`), and no complications exist. **This path is ready today.**

2. **GitHub OAuth for human developers (interactive)** — This is the part that
   needs validation. When a developer runs `step ssh login` from their laptop,
   they need a browser-based OAuth flow that returns an ID token. GitHub's
   standard OAuth flow issues access tokens, not OIDC ID tokens with standard
   claims. A GitHub App would need to be configured specifically for OIDC.

**Verified:** `https://github.com/.well-known/openid-configuration` returns 404.
GitHub's main OAuth is pure OAuth 2.0 (access tokens + `/user` API), not OIDC.
step-ca's OIDC provisioner requires a discovery endpoint and signed JWTs.

**This is a Locaweb implementation detail, invisible to customers.** Locaweb
runs an OIDC bridge (Dex, Keycloak, or custom) alongside step-ca. The bridge
wraps GitHub OAuth into standard OIDC. The developer experience is unchanged:

```
Developer runs:
  step ssh login --provisioner github --ca-url https://ssh-ca.locaweb.com.br

What happens (invisible to developer):
  step CLI → step-ca → OIDC bridge → GitHub OAuth (browser popup)
  Developer clicks "Authorize Locaweb SSH" (standard GitHub OAuth consent)
  OIDC bridge → ID token → step-ca → signed SSH certificate
  Certificate loaded into ssh-agent
```

The developer sees the same "Sign in with GitHub" browser popup they've used
on dozens of other services. The `step` CLI listens on `localhost` for the
OAuth redirect (configurable via `listenAddress`, defaults to `127.0.0.1:10000`).

Locaweb's implementation choices (Dex, Keycloak, custom service) don't affect
the customer-facing API or the cofounder plugin design.

### 7.2 Tenant Isolation Bootstrapping

**Question:** How does a new customer's VM get the right `authorized_principals`?

**Options:**
A. **Cloud-init**: Customer's userdata includes the principals list.
   Simple but the customer must know to include it.

B. **CloudStack metadata**: Locaweb extends CloudStack to store authorized
   principals as VM metadata. The VM image has a script that reads this
   at boot time.

C. **Locaweb API + cloud-init integration**: Customer registers authorized
   users via API. The provisioning workflow automatically includes principals
   in userdata. The cofounder plugin handles this transparently.

Option C is best for the cofounder use case: the plugin calls the Locaweb API
during provisioning, and the workflow template includes the right principals.

### 7.3 Principal Update Without VM Restart

**Question:** Adding a team member requires updating `authorized_principals`
on running VMs. How?

**Options:**
A. SSH in with existing access and update the file (requires someone with
   current access — chicken-and-egg for the first admin).

B. CloudStack VM userdata update + reboot (disruptive).

C. Agent running on VMs that periodically syncs principals from an API
   (like the cron job in the original proposal, but centralized).

D. `AuthorizedPrincipalsCommand` that queries Locaweb's API at SSH time
   (real-time, no sync needed, but adds network dependency to SSH auth).

Option D is most elegant but adds a runtime dependency. Option C is more
robust. Option A works for day-2 operations (first admin is always authorized).

### 7.4 step-ca HA and Availability

**Concern:** If step-ca goes down, no one can get new certificates.

**Mitigations:**
- Two instances behind a load balancer
- Database replication (step-ca supports MySQL/PostgreSQL backends)
- Existing certificates continue working until expiry
- 8h default validity means ~4h of "buffer" during a workday
- Break-glass: CloudStack console access (out-of-band, always available)
- Monitoring and alerting on step-ca health

### 7.5 Is It Worth Building for Locaweb?

**The honest question:** This is a significant platform investment. Is it
justified by the current customer base?

**Arguments for:**
- Differentiating feature vs. other cloud providers
- Reduces support burden (SSH key issues are a common support ticket)
- Foundation for future security features (mTLS, service mesh, etc.)
- Once built, cost per additional customer approaches zero

**Arguments against:**
- Significant engineering investment for Locaweb
- Requires Locaweb to operate a security-critical service
- HSM costs and operational complexity
- Most customers may not value it (SSH "just works" for simple cases)

**Pragmatic middle ground:** Locaweb provides the step-ca service; customers
opt-in. VMs still support both traditional keypairs and certificates.
Adoption grows organically.

---

## 8. What We (Cofounder) Can Do to Prepare

Regardless of whether Locaweb builds this, we can structure the cofounder
plugin to be ready:

### 8.1 Abstract the SSH Authentication Layer

Create an abstraction in the deploy skill that separates "get SSH access"
from "deploy with Kamal":

```
# Current: tightly coupled
Step 3: Generate SSH key
Step 4: Upload to GitHub secrets
Step 7: Workflow uses webfactory/ssh-agent with SSH_PRIVATE_KEY

# Future: pluggable
Step 3: Configure SSH authentication
  - Method A: Static key (current, legacy)
  - Method B: Self-managed CA (Phase 1 of original proposal)
  - Method C: Locaweb-managed CA (this scenario)
Step 7: Workflow uses the configured method
```

### 8.2 Propose the Feature to Locaweb

Package this document as a feature proposal. Emphasize:
1. Customer pain (SSH key rotation causing downtime)
2. Security improvement (short-lived certs, HSM-backed CA)
3. Platform differentiation
4. Foundation for future features (mTLS, host certs, audit)

### 8.3 Build the Self-Managed Version First

The self-managed CA (original proposal Phase 1) is implementable today with
no Locaweb involvement. It solves the same problems, just with more customer
responsibility. If/when Locaweb launches a managed CA, migration is
straightforward: swap the CA public key on VMs, point workflows to
Locaweb's step-ca endpoint.

---

## 9. Architecture Comparison Diagram

```
SCENARIO A: Self-Managed CA (current proposal)
═══════════════════════════════════════════════

  Customer GitHub Org
  ┌─────────────────────┐
  │ Secret:              │
  │  SSH_CA_PRIVATE_KEY  │──── Workflow signs certs in-process
  │                      │     (CA key exposed to runner)
  │ Secret:              │
  │  SSH_CA_PUBLIC_KEY   │──── Passed to cloud-init
  └─────────────────────┘

  Customer VMs
  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
  │ TrustedUserCA│  │ TrustedUserCA│  │ TrustedUserCA│
  │ (via cloud-  │  │ (via cloud-  │  │ (via cloud-  │
  │  init)       │  │  init)       │  │  init)       │
  └──────────────┘  └──────────────┘  └──────────────┘


SCENARIO B: Locaweb-Managed CA (this scenario)
═══════════════════════════════════════════════

  Locaweb Platform
  ┌──────────────────────────────────────────────┐
  │  step-ca (HA)          HSM                   │
  │  ┌──────────┐    ┌──────────────┐            │
  │  │ OIDC     │───▶│ CA Key       │            │
  │  │ Validate │    │ (never       │            │
  │  │ + Sign   │◀───│  exported)   │            │
  │  └──────────┘    └──────────────┘            │
  │       ▲                                      │
  │       │     VM Templates                     │
  │       │     ┌────────────────┐               │
  │       │     │ TrustedUserCA  │               │
  │       │     │ (pre-baked)    │               │
  │       │     └────────────────┘               │
  └───────┼──────────────────────────────────────┘
          │
  Customer GitHub Org
  ┌───────┴─────────────┐
  │ No SSH secrets      │
  │ needed at all!      │
  │                     │
  │ Workflow:           │
  │  OIDC token ──────────▶ step-ca ──▶ cert
  └─────────────────────┘

  Customer VMs (trust inherited from template)
  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
  │ TrustedUserCA│  │ TrustedUserCA│  │ TrustedUserCA│
  │ (pre-baked,  │  │ (pre-baked,  │  │ (pre-baked,  │
  │  zero config)│  │  zero config)│  │  zero config)│
  └──────────────┘  └──────────────┘  └──────────────┘
```

---

## 10. Verdict

The Locaweb-managed CA is the **ideal end-state** but not the practical
starting point. The recommended path:

1. **Now:** Implement self-managed CA (original proposal Phase 1).
   No dependency on Locaweb. Solves all three problems.

2. **Propose:** Share this document with Locaweb as a platform feature request.
   Frame it as "cloud-native SSH" — a differentiator.

3. **If/when Locaweb builds it:** Migration is a configuration change:
   - Swap CA public key on VMs (or just re-provision)
   - Point workflow step-ca calls to `ssh-ca.locaweb.com.br`
   - Delete `SSH_CA_PRIVATE_KEY` from GitHub secrets
   - Done.

The self-managed version is a necessary stepping stone anyway — it validates
the certificate-based approach and surfaces any issues before proposing
platform-wide adoption.
