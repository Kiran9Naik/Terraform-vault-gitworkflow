# Vault + Terraform + GitHub Actions (Plan‑first workflow)

End‑to‑end walkthrough to run **Terraform Plan** in GitHub Actions using **ephemeral AWS credentials from HashiCorp Vault**. This is the same flow you can post with logs/screenshots; you can add Apply/Destroy later.

> **Demo scope:** Plan only. We fetch short‑lived AWS creds from Vault’s AWS Secrets Engine. No `.tfvars` are committed; values are injected at runtime. (For production, replace root token with AppRole/OIDC.)

---

## 0) Prerequisites

* AWS account.
* One **EC2** (Ubuntu) to host Vault (demo only; use TLS + HA in prod).
* IAM user/role in AWS with permissions to create IAM users/keys or assume roles for Vault (for demo we use an access key with wide permissions; scope it down in prod).
* GitHub repo with a basic Terraform project (example below).

---

## 1) Install Vault on EC2

Open TCP **8200** in the instance security group.

```bash
sudo apt-get update && sudo apt-get install -y unzip jq
wget https://releases.hashicorp.com/vault/1.13.0/vault_1.13.0_linux_amd64.zip
mv vault_1.13.0_linux_amd64.zip vault.zip
unzip vault.zip
sudo mv vault /usr/local/bin/
sudo useradd --system --home /etc/vault.d --shell /bin/false vault
sudo mkdir -p /etc/vault.d /opt/vault
sudo chown -R vault:vault /etc/vault.d /opt/vault
```

Create **/etc/vault.d/vault.hcl**:

```hcl
storage "file" {
  path = "/opt/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1  # demo only; use TLS in prod
}

api_addr       = "http://0.0.0.0:8200"
ui             = true
disable_mlock  = true
```

Systemd unit **/etc/systemd/system/vault.service**:

```ini
[Unit]
Description=HashiCorp Vault
After=network.target

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Start Vault:

```bash
sudo chmod 600 /etc/vault.d/vault.hcl
sudo systemctl daemon-reload
sudo systemctl enable vault
sudo systemctl start vault
sudo systemctl status vault
```

Export address (replace with your host/IP):

```bash
export VAULT_ADDR="http://<your-ec2-ip>:8200"
```

Initialize & unseal (save the unseal key and root token safely):

```bash
vault operator init -key-shares=1 -key-threshold=1
vault operator unseal <UNSEAL_KEY>
vault login <ROOT_TOKEN>
```

---

## 2) Configure Vault AWS Secrets Engine

Enable engine and configure AWS root (the access key must be allowed to create IAM users/keys or roles):

```bash
vault secrets enable -path=aws aws
vault write aws/config/root \
  access_key=<AWS_ACCESS_KEY_ID> \
  secret_key=<AWS_SECRET_ACCESS_KEY> \
  region=ap-south-1

vault read aws/config/root   # validate
```

Create a role that issues short‑lived IAM users (demo policy is wide; reduce in prod):

```bash
vault write aws/roles/terraform-role \
  credential_type=iam_user \
  policy_document=-<<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["ec2:*","s3:*","rds:*"], "Resource": "*"}
  ]
}
EOF
```

Test issuance:

```bash
vault read aws/creds/terraform-role
```

> You should see an `access_key`/`secret_key` with a lease/TTL.

---

## 3) Minimal Terraform project

Repository structure:

.
├─ modules/                     # Reusable Terraform modules (e.g., EC2, VPC, RDS, S3, etc.)
│   ├─ ec2/
│      ├─ main.tf
│      ├─ variables.tf
│      └─ outputs.tf
│ 
│
├─ main.tf                      # Root Terraform config (calls modules)
├─ variables.tf                 # Input variables for root module
├─ terraform.tfvars             # (Optional) Variable values
├─ versions.tf                  # Provider + TF version pinning
│
└─ .github/workflows/terraform.yml  

**main.tf** (use env vars for AWS creds; only pass region as a var):


**variables.tf**



> Note: We **do not** commit `.tfvars`. The pipeline will inject values.

---

## 4) GitHub repository secrets/vars

Set these in **Repository → Settings → Secrets and variables**:

**Secrets**

* `VAULT_ROOT_TOKEN` → your Vault root token (demo only).

**Variables** (or keep inline in YAML):

* `VAULT_ADDR` → e.g. `http://<your-ec2-ip>:8200`
* `TF_REGION` → e.g. `ap-south-1`
* `TF_BUCKET_NAME` → e.g. `my-demo-bucket-12345`

---

## 5) GitHub Actions workflow (Plan on PR)

Create **.github/workflows/terraform.yml**:
have a look at  .github/workflows/terraform.yml file 

**Why this works**

* AWS provider automatically uses `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` from env.
* Only non‑secret vars (`region`, `bucket_name`) are passed as Terraform variables.
* No `.tfvars` in the repo.

---

## 6) (Optional) Apply & Destroy workflows

Add later when ready:

* **Apply on merge to main**: same steps; replace `pull_request` with `push` to `main` and run `terraform apply -auto-approve`.
* **Destroy**: separate workflow triggered with `workflow_dispatch`:

```yaml
name: Terraform Destroy (manual)

on: { workflow_dispatch: {} }

jobs:
  destroy:
    runs-on: ubuntu-latest
    env:
      VAULT_ADDR: ${{ vars.VAULT_ADDR }}
      TF_REGION: ${{ vars.TF_REGION }}
      TF_BUCKET_NAME: ${{ vars.TF_BUCKET_NAME }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: |
          sudo apt-get update && sudo apt-get install -y jq unzip
          curl -fsSLo vault.zip https://releases.hashicorp.com/vault/1.13.0/vault_1.13.0_linux_amd64.zip
          unzip -o vault.zip && sudo mv vault /usr/local/bin/
      - run: echo "VAULT_TOKEN=${{ secrets.VAULT_ROOT_TOKEN }}" >> $GITHUB_ENV
      - run: |
          CREDS=$(vault read -format=json aws/creds/terraform-role)
          echo "AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .data.access_key)" >> $GITHUB_ENV
          echo "AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .data.secret_key)" >> $GITHUB_ENV
          echo "AWS_DEFAULT_REGION=$TF_REGION" >> $GITHUB_ENV
      - run: |
          terraform init -input=false
          terraform destroy -auto-approve \
            -var "region=$TF_REGION" \
            -var "bucket_name=$TF_BUCKET_NAME"
```

---

## 7) Notes & hardening for production

* **Never** use root token in CI/CD. Prefer **AppRole** or **OIDC/JWT** with least‑privilege policies.
* Enable **TLS** on Vault listener; don’t run with `tls_disable = 1`.
* Lock down the Vault AWS role policy to only required actions/resources.
* Store non‑secret configs as repo variables; store secrets in Vault (or GitHub Secrets if you must).
* Use **KV** for tfvars if you want to centralize env‑specific values and render a `terraform.tfvars` at runtime.

---

## 8) Troubleshooting quick hits

* `curl --data requires parameter` → your login body is empty/malformed. When using root token, skip login.
* `permission denied` from Vault AWS creds → the AWS access key you configured in `aws/config/root` lacks IAM permissions.
* `secrets engine not enabled at aws/` → run `vault secrets enable -path=aws aws`.
* `operation requires unsealed vault` → run `vault operator unseal`.
* Terraform can’t find AWS creds → confirm env vars are exported in the same step/job, or echo them to `$GITHUB_ENV` as shown.

---

## 9) What to post on LinkedIn

* Screenshot of the successful **Plan** job showing `vault read aws/creds/...` and `terraform plan` summary.
* Short caption: *"Implemented a secure Terraform Plan pipeline using HashiCorp Vault’s AWS Secrets Engine to issue ephemeral IAM credentials. No static keys or tfvars in the repo; values injected at runtime. Apply/Destroy coming next."*

---

That’s it — copy this into your repo as `README.md`, attach your logs/screenshots, and you’re set for a clean LinkedIn showcase.
