# SSH Certificates with GitHub OIDC

Technical study for replacing long-lived SSH keys with short-lived SSH certificates
using GitHub as the identity provider.

Date: 2025-04-02

---

## 1. Problem Statement

The current SSH authentication scheme has three pain points:

| Problem | Current Impact |
|---------|----------------|
| **Long-lived keys on disk** | `~/.ssh/<repo-name>` persists indefinitely. If a laptop is compromised, the attacker gets permanent root SSH access to all provisioned VMs. |
| **Computer migration** | Switching machines requires SSH key rotation — stopping every VM, resetting keys via CloudStack API, restarting VMs. Causes downtime. |
| **Team collaboration** | The SSH private key is a single secret. Adding a team member means either sharing the key (bad) or running a full rotation to register a new one (disruptive). There's no concept of per-user access. |

All three problems stem from the same root cause: **the SSH key is a long-lived, bearer credential tied to a machine, not to a person**.

---

## 2. Proposed Architecture: SSH Certificates

### 2.1 Core Concept

Instead of distributing public keys to every VM (`authorized_keys`), we deploy a single
**SSH Certificate Authority (CA) public key** to every VM (`TrustedUserCAKeys`). Any SSH
certificate signed by this CA is accepted — no per-user key distribution needed.

Certificates are **short-lived** (e.g., 1-16 hours). They naturally expire without
revocation. A compromised certificate is useless after its TTL.

### 2.2 High-Level Flow

```
                      GitHub (OIDC Provider)
                       |                |
           +-----------+                +-----------+
           |                                        |
    Local Developer                         GitHub Actions
    (gh auth / OAuth)                   (OIDC token auto-issued)
           |                                        |
           v                                        v
      SSH CA Service                          SSH CA (in-workflow)
      (step-ca or custom)                   (ssh-keygen -s ca_key)
           |                                        |
           v                                        v
     Short-lived SSH cert                  Short-lived SSH cert
     loaded into ssh-agent                 used by Kamal
           |                                        |
           +----------------+  +--------------------+
                            |  |
                            v  v
                     VMs trust CA public key
                     (TrustedUserCAKeys in sshd_config)
```

### 2.3 What Changes for Each Actor

**For GitHub Actions (Kamal deployment):**
- No more `SSH_PRIVATE_KEY` secret per environment
- Workflow generates an ephemeral key pair, signs it with the CA key, uses the cert
- CA private key stored once as a GitHub secret (`SSH_CA_PRIVATE_KEY`)

**For local developers:**
- Run `step ssh login` (or a custom script using `gh auth`)
- Authenticate via browser-based GitHub OAuth
- Receive a short-lived SSH certificate loaded into `ssh-agent`
- SSH to VMs works transparently — no `-i ~/.ssh/<repo-name>` needed

**For team members:**
- Authorized by GitHub username or org/team membership
- Each member gets their own certificate with their identity as principal
- Adding a member = adding their GitHub username to an allowed list
- Removing a member = removing them; their existing cert expires naturally

**For VMs:**
- `TrustedUserCAKeys /etc/ssh/ssh_user_ca_key.pub` in sshd_config
- No more `authorized_keys` management
- CloudStack keypair mechanism is bypassed

---

## 3. Technical Deep-Dive

### 3.1 SSH Certificate Anatomy

An SSH certificate is a signed data structure containing:

```
Type:           ssh-ed25519-cert-v01@openssh.com
Public key:     ED25519 (ephemeral, generated per session)
Signing CA:     ED25519 (the CA's public key fingerprint)
Key ID:         "gmautner@github.com" (audit trail)
Serial:         42
Valid principals: root
Valid:          2025-04-02T10:00:00 to 2025-04-02T18:00:00
Extensions:     permit-pty, permit-port-forwarding
```

The VM's sshd verifies:
1. The certificate is signed by the trusted CA
2. The certificate hasn't expired
3. The requested principal (`root`) is in the allowed list
4. Extensions permit the operation

### 3.2 GitHub as OIDC Provider

GitHub exposes a standard OIDC configuration at:
```
https://token.actions.githubusercontent.com/.well-known/openid-configuration
```

**For GitHub Actions**, OIDC tokens are automatic. The JWT contains:
```json
{
  "sub": "repo:gmautner/my-app:ref:refs/heads/main",
  "repository": "gmautner/my-app",
  "actor": "gmautner",
  "job_workflow_ref": "gmautner/my-app/.github/workflows/deploy.yml@refs/heads/main",
  "iss": "https://token.actions.githubusercontent.com",
  "aud": "api://SSHCertExchange"
}
```

**For human users**, GitHub's OAuth is pure OAuth 2.0 (access tokens + API),
**not** OIDC. `https://github.com/.well-known/openid-configuration` returns 404.
Web apps using "Sign in with GitHub" call the `/user` API with the access
token — they don't receive signed ID tokens. step-ca needs proper OIDC.
The solution is **Dex** (dexidp.io) — a lightweight OIDC bridge with a native
GitHub connector that wraps GitHub OAuth into standard OIDC ID tokens.

### 3.3 Two Implementation Paths

#### Path A: Lightweight (No step-ca) — Recommended for Phase 1

For GitHub Actions, the CA signing happens directly in the workflow:

```yaml
# In the deploy workflow
- name: Generate ephemeral SSH key and certificate
  env:
    SSH_CA_PRIVATE_KEY: ${{ secrets.SSH_CA_PRIVATE_KEY }}
  run: |
    # Write CA key
    install -m 600 /dev/null /tmp/ca_key
    printf '%s\n' "$SSH_CA_PRIVATE_KEY" > /tmp/ca_key

    # Generate ephemeral key pair
    ssh-keygen -t ed25519 -f /tmp/ephemeral -N "" -q

    # Sign it with the CA (valid 1 hour, principal: root)
    ssh-keygen -s /tmp/ca_key \
      -I "gha-${{ github.repository }}-${{ github.run_id }}" \
      -n root \
      -V +1h \
      /tmp/ephemeral.pub

    # Load into agent
    eval $(ssh-agent -s)
    ssh-add /tmp/ephemeral

    # Cleanup CA key immediately
    rm -f /tmp/ca_key
```

For local developers, a small helper script:

```bash
#!/bin/bash
# ssh-cert-login: get a short-lived SSH certificate via GitHub OAuth
# Requires: gh CLI authenticated, access to a signing endpoint

# Option 1: Call a GitHub Actions workflow that signs and returns a cert
# Option 2: Call a lightweight signing service (Lambda, Cloud Run, etc.)
# Option 3: Use step-ca with GitHub OIDC provisioner

ssh-keygen -t ed25519 -f /tmp/ssh_cert_key -N "" -q
gh workflow run sign-ssh-cert.yml \
  -f public_key="$(cat /tmp/ssh_cert_key.pub)" \
  --repo gmautner/locaweb-cloud-provision
# ... retrieve signed certificate ...
ssh-add /tmp/ssh_cert_key
```

#### Path B: Full step-ca + Dex (Recommended for Phase 2 / scale)

Deploy `step-ca` as a container (can run on one of the existing VMs or as a
separate small instance). Deploy **Dex** alongside it as an OIDC bridge for
human users (GitHub's OAuth is not OIDC-compliant — no `.well-known/openid-configuration`).

```bash
# 1. GitHub Actions OIDC provisioner (for CI/CD) — works directly
step ca provisioner add github-actions --type OIDC \
  --configuration-endpoint \
    https://token.actions.githubusercontent.com/.well-known/openid-configuration \
  --client-id "api://SSHCertExchange" \
  --listen-address ":443" \
  --ssh

# 2. Dex OIDC provisioner (for human users via GitHub OAuth → Dex → OIDC)
step ca provisioner add github-users --type OIDC \
  --configuration-endpoint \
    https://dex.example.com/.well-known/openid-configuration \
  --client-id "$DEX_CLIENT_ID" \
  --client-secret "$DEX_CLIENT_SECRET" \
  --ssh
```

Dex config (~30 lines) bridges GitHub OAuth into proper OIDC:
```yaml
# dex-config.yaml
issuer: https://dex.example.com
connectors:
  - type: github
    id: github
    name: GitHub
    config:
      clientID: $GITHUB_OAUTH_APP_CLIENT_ID
      clientSecret: $GITHUB_OAUTH_APP_CLIENT_SECRET
      redirectURI: https://dex.example.com/callback
      orgs:
        - name: your-github-org  # restrict to org members
staticClients:
  - id: step-ca
    name: step-ca
    secret: $DEX_CLIENT_SECRET
    redirectURIs:
      - http://127.0.0.1:10000  # step CLI callback
```

Then developers simply run:
```bash
step ssh login gmautner --provisioner github-users
# Opens browser → Dex → GitHub OAuth → Dex issues OIDC ID token → step-ca signs cert
ssh root@<vm-ip>   # certificate in agent, no -i flag needed
```

### 3.4 VM-Side Configuration

Regardless of path, VMs need this in `/etc/ssh/sshd_config`:

```
# Trust certificates signed by our CA
TrustedUserCAKeys /etc/ssh/ssh_user_ca_key.pub

# Map GitHub usernames to system users
AuthorizedPrincipalsFile /etc/ssh/authorized_principals

# Optional: command to dynamically resolve principals
# AuthorizedPrincipalsCommand /usr/local/bin/check-github-team %u %i
# AuthorizedPrincipalsCommandUser nobody
```

And `/etc/ssh/authorized_principals`:
```
root
```

The CA public key (`ssh_user_ca_key.pub`) is deployed via cloud-init userdata.

---

## 4. Implementation Plan

### Phase 1: Certificate-based auth for GitHub Actions (low risk, high value)

This phase eliminates `SSH_PRIVATE_KEY` / `SSH_PRIVATE_KEY_PRODUCTION` secrets and
replaces them with a single `SSH_CA_PRIVATE_KEY` secret per org (not per repo).

#### 4.1 Generate SSH CA key pair

```bash
ssh-keygen -t ed25519 -f ssh_ca -N "passphrase" -C "locaweb-cloud-ssh-ca"
# ssh_ca     → CA private key (store as GitHub org secret SSH_CA_PRIVATE_KEY)
# ssh_ca.pub → CA public key  (deploy to VMs via cloud-init)
```

#### 4.2 Changes to `locaweb-cloud-provision`

| File | Change |
|------|--------|
| `scripts/userdata/web_vm.sh` | Add: install CA public key to `/etc/ssh/ssh_user_ca_key.pub`, add `TrustedUserCAKeys` to sshd_config, create `/etc/ssh/authorized_principals` with `root`, restart sshd |
| `scripts/userdata/worker_vm.sh` | Same as above |
| `scripts/userdata/accessory_vm.sh` | Same as above |
| `scripts/provision_infrastructure.py` | **Keep** keypair registration as fallback during transition. Add CA pubkey as a workflow input. |
| `.github/workflows/provision.yml` | Accept `SSH_CA_PUBLIC_KEY` secret. Pass it to userdata scripts (e.g., via base64-encoded env var in cloud-init). |
| `scripts/rotate_ssh_key.py` | **Deprecate** — certificate rotation is just waiting for expiry |
| `.github/workflows/rotate-ssh-key.yml` | **Deprecate** after migration |

Cloud-init addition to all userdata scripts:

```bash
# --- SSH Certificate Authority ---
cat > /etc/ssh/ssh_user_ca_key.pub << 'CAEOF'
@@SSH_CA_PUBLIC_KEY@@
CAEOF

echo "TrustedUserCAKeys /etc/ssh/ssh_user_ca_key.pub" >> /etc/ssh/sshd_config
echo "root" > /etc/ssh/authorized_principals
echo "AuthorizedPrincipalsFile /etc/ssh/authorized_principals" >> /etc/ssh/sshd_config
systemctl restart sshd
```

#### 4.3 Changes to deploy workflows (caller side, generated by cofounder)

```yaml
# Before (current):
- uses: webfactory/ssh-agent@v0.9.0
  with:
    ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

# After (certificate-based):
- name: Generate ephemeral SSH certificate
  env:
    SSH_CA_PRIVATE_KEY: ${{ secrets.SSH_CA_PRIVATE_KEY }}
  run: |
    install -m 600 /dev/null /tmp/ca_key
    printf '%s\n' "$SSH_CA_PRIVATE_KEY" > /tmp/ca_key
    ssh-keygen -t ed25519 -f /tmp/deploy_key -N "" -q
    ssh-keygen -s /tmp/ca_key \
      -I "deploy-${{ github.repository }}-run${{ github.run_id }}" \
      -n root -V +1h \
      /tmp/deploy_key.pub
    rm -f /tmp/ca_key
- uses: webfactory/ssh-agent@v0.9.0
  with:
    ssh-private-key: /tmp/deploy_key
# Note: webfactory/ssh-agent loads the cert automatically if
# /tmp/deploy_key-cert.pub exists alongside the private key
```

#### 4.4 Changes to `marketplace/plugins/cofounder`

| File | Change |
|------|--------|
| `skills/app-deploy/SKILL.md` | Update Step 3 (SSH key generation) to generate CA key pair instead. Update workflow templates. |
| `skills/app-deploy/references/workflows.md` | Update caller workflow examples with certificate-based auth. |
| `skills/ssh-key-rotation/SKILL.md` | Deprecate. Replace with "CA key rotation" (much simpler — update secret + re-provision). |
| Agent description | Update SSH-related instructions. |

### Phase 2: Certificate-based auth for local developers

#### 4.5 Option A: Signing via GitHub Actions workflow_dispatch

Create a workflow in `locaweb-cloud-provision`:

```yaml
name: Sign SSH Certificate
on:
  workflow_dispatch:
    inputs:
      public_key:
        description: 'User SSH public key to sign'
        required: true
      principal:
        description: 'SSH principal (default: root)'
        default: 'root'
      validity:
        description: 'Certificate validity (default: 8h)'
        default: '8h'

jobs:
  sign:
    runs-on: ubuntu-latest
    steps:
      - name: Sign certificate
        env:
          SSH_CA_PRIVATE_KEY: ${{ secrets.SSH_CA_PRIVATE_KEY }}
        run: |
          install -m 600 /dev/null /tmp/ca_key
          printf '%s\n' "$SSH_CA_PRIVATE_KEY" > /tmp/ca_key
          echo "${{ inputs.public_key }}" > /tmp/user.pub
          ssh-keygen -s /tmp/ca_key \
            -I "${{ github.actor }}" \
            -n "${{ inputs.principal }}" \
            -V "+${{ inputs.validity }}" \
            /tmp/user.pub
          cat /tmp/user-cert.pub
          rm -f /tmp/ca_key
```

Local developer workflow:
```bash
ssh-keygen -t ed25519 -f /tmp/ssh_session -N "" -q
gh workflow run sign-ssh-cert.yml \
  -f public_key="$(cat /tmp/ssh_session.pub)" \
  --repo gmautner/locaweb-cloud-provision
# Wait for run, download cert from logs/artifacts
ssh-add /tmp/ssh_session   # cert auto-loaded if -cert.pub exists alongside
ssh root@<vm-ip>
```

**Caveat:** Retrieving the signed certificate from a workflow run is clunky
(need to use artifacts or parse logs). This works but isn't elegant.

#### 4.6 Option B: Deploy step-ca (better UX, more infra)

Run step-ca on a small VM or container. Configure GitHub OAuth App as OIDC
provisioner. Developers get a seamless experience:

```bash
step ssh login --provisioner github
# Opens browser → GitHub OAuth → certificate in ssh-agent
ssh root@<vm-ip>
```

**Trade-off:** More infrastructure to manage but much better UX. Consider
this when there are 3+ team members regularly needing SSH access.

### Phase 3: Team member management

With certificate-based auth, team management becomes:

```
# /etc/ssh/authorized_principals on each VM
root
gmautner
teammate1
teammate2
```

Or dynamically via `AuthorizedPrincipalsCommand` that checks GitHub team membership:

```bash
#!/bin/bash
# /usr/local/bin/check-github-team
# Called by sshd with args: %u (requested user) %i (cert key ID / principal)
REQUESTED_USER=$1
CERT_PRINCIPAL=$2

# If requesting root, check if principal is in the team
if [ "$REQUESTED_USER" = "root" ]; then
  # Check against a file synced periodically from GitHub API
  grep -qx "$CERT_PRINCIPAL" /etc/ssh/allowed_github_users && echo root
fi
```

A cron job on each VM syncs the allowed users list:
```bash
curl -s https://api.github.com/orgs/YOUR_ORG/teams/YOUR_TEAM/members \
  | jq -r '.[].login' > /etc/ssh/allowed_github_users
```

---

## 5. Caveats and Gotchas

### 5.1 CloudStack Keypair Mechanism

**Issue:** CloudStack's `deployVirtualMachine` with `keypair=` parameter injects
the public key into `authorized_keys` via cloud-init. The `resetSSHKeyForVirtualMachine`
API replaces it. With certificates, this mechanism is bypassed.

**Mitigation:** During Phase 1, keep the keypair mechanism as a **fallback**. Deploy
VMs with both:
- A keypair (traditional `authorized_keys` — for break-glass access)
- CA public key via userdata (for certificate-based auth — primary method)

Remove the keypair fallback in Phase 2 after confidence is established.

### 5.2 CA Key Compromise

**Issue:** If `SSH_CA_PRIVATE_KEY` is compromised, an attacker can sign certificates
for any principal. This is the same blast radius as compromising any GitHub org secret,
but the impact is higher.

**Mitigations:**
- Passphrase-protect the CA key (ssh-keygen supports this; need to pass passphrase
  in the workflow)
- Store in GitHub org-level secrets (not repo-level) to limit exposure
- Rotate the CA key annually (re-deploy CA public key to all VMs)
- Consider HSM-backed CA key for Phase 2 (step-ca supports YubiKey/PKCS#11)

### 5.3 CA Availability (Phase 2 only)

**Issue:** If step-ca is down, no new certificates can be issued. Existing
certificates continue to work until expiry.

**Mitigations:**
- Set certificate validity to 8-16 hours (developers don't need 24/7 access)
- Keep a break-glass static key (stored offline, in a safe) for emergencies
- step-ca is stateless enough to recover quickly from backups

### 5.4 GitHub Actions OIDC Token Security

**Issue:** Any workflow in any branch can request an OIDC token. A malicious PR
could add a workflow step that uses the OIDC token.

**Mitigation:** This is mitigated by the existing PR review process and the fact
that `SSH_CA_PRIVATE_KEY` is a separate secret (OIDC token alone doesn't grant
SSH access in the lightweight Path A approach). In Path B (step-ca), configure
the provisioner to restrict by `job_workflow_ref` claim to specific workflows.

### 5.5 Certificate Principal Security

**Issue:** Certificates specify which user they can log in as. If the principal
is `root`, anyone with a valid certificate gets root access.

**Design decision:** For simplicity, keep `root` as the only principal (matches
current behavior where everyone SSH's as root). For better audit trails,
use per-user principals and `sudo`.

### 5.6 Existing VMs (Migration)

**Issue:** VMs provisioned before this change don't have `TrustedUserCAKeys`.

**Mitigation:** Run a one-time migration script that SSH's into each existing
VM (using the current keypair) and:
1. Installs the CA public key
2. Updates sshd_config
3. Restarts sshd
4. Verifies certificate auth works
5. Optionally removes old authorized_keys entry

### 5.7 webfactory/ssh-agent Compatibility

**Issue:** The `webfactory/ssh-agent` GitHub Action loads SSH keys into the agent.
It needs to handle certificates correctly.

**Detail:** OpenSSH's `ssh-add` automatically loads a certificate if
`<keyfile>-cert.pub` exists alongside the private key. The webfactory action
writes the key to a temp file — we need to ensure the cert file is placed
alongside it, or we load the key ourselves without the action.

**Alternative:** Skip webfactory/ssh-agent entirely and manage the agent directly:
```yaml
- name: Set up SSH with certificate
  run: |
    eval $(ssh-agent -s)
    echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" >> $GITHUB_ENV
    echo "SSH_AGENT_PID=$SSH_AGENT_PID" >> $GITHUB_ENV
    ssh-add /tmp/deploy_key   # loads cert automatically
```

### 5.8 Host Key Verification

**Issue:** Currently, all SSH connections use `StrictHostKeyChecking=no` and
`UserKnownHostsFile=/dev/null`. This is insecure (MITM possible) but pragmatic
for dynamic infrastructure.

**Opportunity:** With an SSH CA, we can also sign **host certificates**. VMs would
get a host certificate signed by the CA at boot time. Clients trust the CA for
host verification too — eliminating both TOFU warnings and the need to disable
host key checking. This is a natural extension but not required for Phase 1.

---

## 6. Security Analysis

### What Improves

| Aspect | Before (static keys) | After (certificates) |
|--------|---------------------|---------------------|
| Credential lifetime | Indefinite | 1-16 hours |
| Compromise impact | Permanent access until rotation | Access expires automatically |
| Key on disk | `~/.ssh/<repo>` always present | Ephemeral, in ssh-agent memory only |
| Computer migration | Full rotation (downtime) | Just re-authenticate |
| Team access | Share key or complex rotation | Per-user certs, no key sharing |
| Audit trail | All access looks the same | Certificate Key ID identifies who |
| Revocation | Manual rotation of all VMs | Wait for expiry (or revoke at CA) |

### What Stays the Same

- Root access model (everyone logs in as root)
- Network-level security (CloudStack firewall rules, fail2ban)
- Deployment flow (Kamal via SSH)

### New Risks

- CA key is a high-value target (single point of trust)
- Dependency on GitHub as identity provider
- New operational complexity (CA management in Phase 2)

---

## 7. Alternatives Considered

### 7.1 Teleport / Boundary

Full-featured SSH access management solutions. **Too heavy** for the current
scale. Better suited for 50+ engineers with compliance requirements.

### 7.2 GitHub SSH Keys (`github.com/<user>.keys`)

GitHub exposes users' public SSH keys. Could deploy these to `authorized_keys`
instead of a shared key. **Problems:** Keys are still long-lived, need periodic
sync, and don't solve the core certificate-vs-key issue.

### 7.3 AWS SSM / Cloud provider-native access

Not applicable — infrastructure is on CloudStack (Locaweb), not AWS/GCP/Azure.

### 7.4 WireGuard VPN + SSH

Layer a VPN. Adds complexity without solving the key management problem.
Could be complementary but not a replacement.

---

## 8. Recommended Roadmap

```
Phase 1 (immediate, low risk):
  ├── Generate SSH CA key pair
  ├── Store CA private key as GitHub org secret
  ├── Update cloud-init userdata to install CA public key + TrustedUserCAKeys
  ├── Update deploy workflows to generate ephemeral certs
  ├── Keep existing keypair mechanism as fallback
  └── Migrate existing VMs via one-time script

Phase 2 (after validation):
  ├── Remove keypair fallback from provisioning
  ├── Deprecate ssh-key-rotation skill
  ├── Implement local developer cert signing (workflow_dispatch or step-ca)
  └── Add host certificates (eliminate StrictHostKeyChecking=no)

Phase 3 (team scale):
  ├── Deploy step-ca for automated certificate issuance
  ├── Configure GitHub OAuth provisioner for human access
  ├── Implement AuthorizedPrincipalsCommand for team membership
  └── Per-user principals with sudo for audit trails
```

---

## 9. Proof of Concept Checklist

To validate this approach before full implementation:

- [ ] Generate a CA key pair locally
- [ ] Spin up a test VM with `TrustedUserCAKeys` configured
- [ ] Sign a certificate with `ssh-keygen -s` and verify SSH access works
- [ ] Verify certificate expiry blocks access after TTL
- [ ] Test in a GitHub Actions workflow (generate + sign + Kamal deploy)
- [ ] Test `webfactory/ssh-agent` or direct `ssh-add` with certificates
- [ ] Verify Kamal works with certificate-based auth (no behavioral change expected)

---

## 10. Key Decisions Needed

1. **Phase 1 scope**: Start with GitHub Actions only, or include local developer
   access from the start?

2. **CA key protection**: Passphrase-protected in GitHub secrets, or plain?
   (Passphrase adds complexity to workflow scripts.)

3. **Certificate validity for CI/CD**: 1 hour should be sufficient. Confirm.

4. **Certificate validity for developers**: 8h (workday) or 16h?

5. **Break-glass mechanism**: Keep one static key stored offline in a password
   manager, or rely on CloudStack console access?

6. **Host certificates**: Include in Phase 1 or defer to Phase 2?
