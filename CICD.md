# CI/CD — Deploying Databricks on GCP from GitHub Actions

How this repo deploys, re-deploys, and tears down a Databricks-on-GCP workspace
**from GitHub Actions**, using keyless Workload Identity Federation (WIF/OIDC),
remote Terraform state, and a strict separation between the *bootstrap* and
*workload* layers.

> Companion docs: `README.md` (overview) · `DEPLOYMENT_GUIDE.md` (operational runbook +
> IAM floor §6) · `TERRAFORM_PRIMER.md` (Terraform concepts) · `bootstrap/README.md`
> (new-project landing zone). This file focuses on the **automation**.

---

## 1. Architecture at a glance

```
                       ┌────────────────────────────────────────────┐
   GitHub Actions      │  google-github-actions/auth@v2 (OIDC)      │
   (this repo)  ─────►  │  no exported keys — short-lived token        │
                       └───────────────────┬────────────────────────┘
                                           │ impersonates
                                           ▼
                         Automation Service Account  (Databricks Account Admin)
                                           │
            ┌──────────────────────────────┼──────────────────────────────┐
            ▼                               ▼                              ▼
   GCP google provider          Databricks provider            GCS backend (state)
   (VPC, subnet, NAT,           (mws_networks, mws_workspaces,  gs://databricks-tfstate-<project>
    firewalls, SAs, DBFS)        permission_assignment)          prefix: databricks/<env>
```

Two layers, deliberately owned by **different identities**:

| Layer | Config | Runs as | Frequency | State prefix |
|-------|--------|---------|-----------|--------------|
| **Bootstrap** | `bootstrap/` | a **project owner** | once per project | `bootstrap` |
| **Workload** | root (`main.tf` + `modules/`) | the **automation SA** | every deploy/destroy | `databricks/<env>` |

The golden rule that shapes everything here: **an identity must never Terraform-manage
its own permissions.** The workload SA runs the workload; the owner-run bootstrap layer
grants the SA its powers. (See §8 for the incident that taught us this.)

---

## 2. Authentication — keyless WIF/OIDC

There are **no service-account keys** anywhere. On each run, GitHub mints a short-lived
OIDC token; `google-github-actions/auth@v2` exchanges it (via the WIF provider) for
credentials that impersonate the automation SA.

- **GCP provider** → uses those WIF credentials directly (Application Default Credentials).
- **Databricks provider** → the SA is a **Databricks Account Admin**; with
  `DATABRICKS_GOOGLE_SERVICE_ACCOUNT` set to that SA, the provider mints a Google **ID
  token** to authenticate to `accounts.gcp.databricks.com`. This needs the SA to hold
  `serviceAccountTokenCreator` **on itself** (self-impersonation).

The WIF provider is scoped by attribute condition
`assertion.repository_owner == '<owner>'`, so any repo under your GitHub owner can
authenticate — no per-repo reconfiguration.

---

## 3. Remote Terraform state (GCS)

CI runners are ephemeral, so state must be remote and shared with local runs.

- Backend is a **partial** `backend "gcs" {}` in `main.tf`; bucket + prefix are supplied at
  init time, so no project-specific value is committed:
  ```bash
  terraform init \
    -backend-config="bucket=databricks-tfstate-<project>" \
    -backend-config="prefix=databricks/<env>"
  ```
- The bucket is **versioned** (state recovery) with public access prevention.
- Per-environment `prefix` keeps `dev` / `test` / `prod` state isolated in one bucket.
- Locally, `deploy.sh`/`teardown.sh` derive the same bucket/prefix; `backend.hcl`
  (gitignored) is the local convenience copy.

---

## 4. Secrets vs. inputs — the "where does config live" model

| Where | What | Why |
|-------|------|-----|
| **GitHub Environment secrets** (dev/test/prod) | `GCP_PROJECT_ID`, `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT`, `DATABRICKS_ACCOUNT_ID`, `DATABRICKS_ADMIN_USER` | Sensitive + differ per environment. Scoping to a GitHub **Environment** enables prod protection (required reviewers). |
| **`workflow_dispatch` dropdown inputs** | `environment`, `action`, `region`, `workspace_name` | Non-sensitive run-time choices. The `environment` pick selects which Environment's secrets load. |

Terraform receives the sensitive values as `TF_VAR_*` env vars (never committed). The
first three secrets are typically shared with your other GCP workflows (VM, Cloud Run).

---

## 5. The workflows

### `deploy` — `.github/workflows/databricks-deploy.yml`
Manual `workflow_dispatch`. Inputs: `environment` (dev/test/prod), `action`
(plan/apply/destroy), `region`, `workspace_name` (blank ⇒ `databricks-gcp-<env>`).

- `plan` — dry run (safe; runs for every action as the front half).
- `apply` — create/update the workspace (~15–20 min; GKE is the slow part).
- `destroy` — tears down, with **automatic orphaned-firewall cleanup**: Databricks leaves
  untracked `db-*` firewall rules in the VPC that block its deletion; the destroy step
  retries up to 3×, deleting those rules between attempts.
- `concurrency` + GCS state locking prevent overlapping runs per environment.

### `validate` — `.github/workflows/terraform-validate.yml`
Automatic on push/PR touching `*.tf`. Runs `terraform fmt -check -recursive` and
`terraform validate` on **both** roots (workload + `bootstrap/`). Uses `-backend=false`,
so it needs **no credentials** and can't touch cloud state — a fast correctness gate.

---

## 6. Running a deployment

1. **Actions → "Deploy Databricks Workspace" → Run workflow.**
2. Pick `environment: dev`, `action: plan`, `region: us-central1`, leave `workspace_name` blank.
3. Review the plan (a fresh build shows ~32 to add).
4. Run again with `action: apply`. On success the job **Summary** prints the workspace URL.
5. To tear down: same workflow, `action: destroy`.

That's the entire round-trip — destroy and re-deploy are both one dispatch each, and have
been validated end-to-end through CI.

---

## 7. Bootstrapping a brand-new GCP project

The workload assumes the automation SA + WIF + IAM floor already exist. For a **new**
project, provision them once with the `bootstrap/` layer (run as a project owner):

```bash
# 0. one-time state bucket (chicken-and-egg: TF can't hold its own backend's bucket)
gcloud storage buckets create gs://databricks-tfstate-<project> \
  --location=us-central1 --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://databricks-tfstate-<project> --versioning

# 1. provision SA + IAM floor + WIF
cd bootstrap
cp bootstrap.tfvars.example bootstrap.tfvars     # fill in (gitignored)
terraform init -backend-config="bucket=databricks-tfstate-<project>" -backend-config="prefix=bootstrap"
terraform apply -var-file=bootstrap.tfvars
terraform output          # -> GCP_* values for GitHub secrets
```

Then the **one un-automatable step**: add the SA as an **Account Admin** in the Databricks
console (no GCP API for this). Set the 5 GitHub Environment secrets, and you're ready to run
the deploy workflow. Full details: `bootstrap/README.md`.

---

## 8. Teardown / decommission

- **Workspace teardown:** deploy workflow with `action: destroy`.
- **Full project decommission:** **delete the GCP project.** That removes the SA, all IAM
  bindings, WIF, and APIs atomically. We deliberately do **not** automate surgical role
  removal — that's the exact operation that self-locks the automation SA (see §9).

---

## 9. Design decisions & lessons learned

**Never let an automation identity manage its own IAM.**
Originally the workload Terraform granted the automation SA its own bootstrap roles. Because
CI runs *as* that SA, a `destroy` removed the SA's `projectIamAdmin` mid-run, after which it
could no longer `setIamPolicy` to delete its last binding → `403 Policy update access denied`.
Fix: those grants were removed from the workload and moved to the owner-run `bootstrap/`
layer. The workload SA now manages the workload, never itself.

**Separate state, shared bucket.** Bootstrap and workload keep separate state (different
prefixes) so the two lifecycles never collide.

**Bare names, not self-links.** `databricks_mws_networks` must receive the VPC/subnet as
bare names (`databricks-vpc-dev`), not GCP self-links — see `DEPLOYMENT_GUIDE.md` §11.

**Secrets stay out of Git.** Real `*.tfvars` and `backend.hcl` are gitignored; only
`*.example` templates are committed. CI passes real values via `TF_VAR_*`/secrets. The repo
is public, so identifiers live only in secrets and gitignored files.

**Full zero-touch is impossible — and that's fine.** Adding the SA as a Databricks Account
Admin is console-only. So the reproducible flow is: *owner bootstraps → one console click →
CI owns the rest.*

---

## 10. Quick reference

| Task | How |
|------|-----|
| Deploy / update | Deploy workflow → `action: apply` |
| Tear down | Deploy workflow → `action: destroy` |
| Dry run | Deploy workflow → `action: plan` |
| Validate code | automatic on push/PR (or run `Terraform Validate` manually) |
| New project | `bootstrap/` (§7) then set secrets |
| Decommission | delete the GCP project |
| Local deploy | `./scripts/deploy.sh dev` · teardown `./scripts/teardown.sh dev` |
