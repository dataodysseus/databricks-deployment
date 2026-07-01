# Terraform Primer — Learning From This Project

A from-scratch guide to the Terraform concepts and techniques used to build this
Databricks-on-GCP deployment. Every example below is **real code from this repo**,
so you can open the referenced file and see it in context.

> New to Terraform? Read top to bottom once. Already comfortable? Jump to
> [§10 Techniques Cheat-Sheet](#10-techniques-cheat-sheet).

---

## 1. What Terraform actually is

Terraform is **Infrastructure as Code (IaC)**. Instead of clicking around the GCP
and Databricks consoles, you *declare* the infrastructure you want in text files
(`.tf`), and Terraform figures out the API calls to make reality match your files.

Three ideas underpin everything:

1. **Declarative, not imperative.** You describe the *desired end state* ("a VPC
   named X should exist"), not the steps. Terraform computes the difference between
   what exists and what you declared, then does only what's needed.
2. **State.** Terraform records what it created in a `terraform.tfstate` file so it
   can tell the difference between "not created yet" and "already exists, unchanged."
3. **Providers.** Plugins that translate your declarations into real API calls. This
   project uses two: `google` (for GCP) and `databricks` (for the workspace).

The payoff you already saw: we **destroyed** the whole workspace and **re-created an
identical one** with two commands. That repeatability is the entire point of IaC.

---

## 2. The core workflow (the loop you'll run forever)

```
terraform init      # download providers, set up the working dir  (once per new/changed setup)
terraform plan      # DRY RUN: show what would change, no changes made
terraform apply     # actually create/update/delete to match your .tf files
terraform destroy   # tear everything in state back down
```

- **`init`** reads `main.tf`, sees it needs the `google` and `databricks` providers,
  downloads them into a hidden `.terraform/` folder, and writes exact versions to
  `.terraform.lock.hcl`.
- **`plan`** is your safety net. It prints a diff with `+` (create), `~` (change),
  `-` (destroy). You saw `Plan: 36 to add, 0 to change, 0 to destroy.` — that's plan
  telling you it will build 36 new things and touch nothing existing.
- **`apply`** does the work and updates state. `apply` runs its own plan first and
  asks for confirmation (our scripts pass `-auto-approve` to skip the prompt).
- **`destroy`** is `apply` in reverse.

In this repo those are wrapped by `scripts/deploy.sh` and `scripts/teardown.sh` so
you don't have to remember the flags — but they run exactly these commands underneath.

---

## 3. Providers — how Terraform talks to GCP and Databricks

Open `main.tf` (lines 6–19). Every Terraform project starts with a `terraform {}`
block declaring which providers and versions it needs:

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google     = { source = "hashicorp/google",       version = "~> 5.0"  }
    databricks = { source = "databricks/databricks",   version = "~> 1.40" }
  }
}
```

- `~> 5.0` means "any 5.x, but not 6.0" — pin ranges so an upstream release doesn't
  silently break you. The **exact** resolved versions are frozen in
  `.terraform.lock.hcl` (commit that file so every run uses identical plugins).

Then you configure each provider (`main.tf` lines 31–49):

```hcl
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "databricks" {
  alias      = "accounts"                          # <-- named/aliased provider
  host       = "https://accounts.gcp.databricks.com"
  account_id = var.databricks_account_id
}
```

### Two techniques worth understanding here

**(a) Aliased providers.** We declare the `databricks` provider *twice* — once with
`alias = "accounts"` (account-level API, where workspaces are created) and once with
`alias = "workspace"` (a specific workspace's API). A resource then picks which one it
uses with `provider = databricks.accounts`. You need this whenever you talk to two
endpoints of the same provider.

**(b) Credentials come from the environment, not the code.** Notice there are **no
passwords or keys** in these files. That's deliberate and correct. Auth is supplied
by environment variables that `scripts/deploy.sh` sets:

```bash
export DATABRICKS_HOST="https://accounts.gcp.databricks.com"
export DATABRICKS_ACCOUNT_ID="<your-databricks-account-id>"
export DATABRICKS_GOOGLE_SERVICE_ACCOUNT="your-automation-sa@..."
```

- The `google` provider authenticates via **Application Default Credentials (ADC)** —
  the `gcloud auth application-default login` you're logged in as.
- The `databricks` provider sees `DATABRICKS_GOOGLE_SERVICE_ACCOUNT` and performs
  **service-account impersonation** to mint a Google OIDC token, which the Databricks
  account accepts because that SA is an account admin.

**Rule of thumb:** never hardcode secrets in `.tf` files. Use env vars, ADC, or a
secrets manager. `.tf` files get committed to git; credentials must not.

---

## 4. Resources — the nouns of your infrastructure

A `resource` block creates one real thing. The pattern is always:

```hcl
resource "<TYPE>" "<LOCAL_NAME>" {
  ...arguments...
}
```

Example from `modules/gcp-networking/main.tf` (lines 6–11):

```hcl
resource "google_compute_network" "databricks_vpc" {
  name                    = "${var.network_name}-${var.environment}"
  project                 = var.project_id
  auto_create_subnetworks = false
  description             = "VPC for Databricks on GCP (${var.environment})"
}
```

- `google_compute_network` is the **type** (defined by the google provider).
- `databricks_vpc` is the **local name** — how *you* refer to it elsewhere in
  Terraform. It is NOT the name in GCP; the actual GCP name is the `name` argument.
- You reference this resource's attributes as
  `google_compute_network.databricks_vpc.id`.

This project's resources, by module:

| Module                    | Real resources it creates                                       |
|---------------------------|------------------------------------------------------------------|
| `gcp-networking`          | VPC, subnet (+ secondary ranges), Cloud Router, Cloud NAT, 2 firewalls |
| `gcp-iam`                 | 2 service accounts + their role bindings, DBFS bucket, API enablement, automation-SA grants |
| `databricks-workspace`    | `databricks_mws_networks`, `databricks_mws_workspaces`          |
| root (`workspace_access`) | user lookup + workspace admin assignment                        |

---

## 5. Variables, `.tfvars`, and `locals` — making it reusable

Hardcoding `us-central1` everywhere would make this deployment single-use. Terraform
has three ways to parameterize.

### Input variables (`variable`) — the knobs
Declared in `variables.tf`:

```hcl
variable "gcp_region" {
  description = "GCP region for all resources"
  type        = string
  default     = "us-central1"
}

variable "databricks_account_id" {
  type      = string
  sensitive = true            # <-- hides the value in plan/apply output
}
```

- `type` gives you validation (string, number, bool, list, map, object…).
- `default` makes it optional; no default means Terraform *must* be given a value.
- `sensitive = true` stops Terraform from printing the value in logs — used here for
  the account ID.
- `variables.tf` even has a **validation block** on `environment` restricting it to
  `dev|staging|prod` (lines 22–25). Bad input fails fast with a clear message.

### Variable *values* (`.tfvars`) — the settings per environment
`environments/dev/dev.tfvars` supplies the actual values:

```hcl
gcp_project_id        = "your-gcp-project-id"
environment           = "dev"
databricks_account_id = "<DATABRICKS_ACCOUNT_ID>"
network_name          = "databricks-vpc"
```

You pass it with `-var-file`:

```bash
terraform apply -var-file=environments/dev/dev.tfvars
```

This is why there's a `dev/` and a `prod/` folder: **same code, different values.**
To spin up a prod copy you'd run the identical code with `prod.tfvars`. That
separation is a core IaC technique — code is generic, configuration is per-environment.

### Local values (`locals`) — computed shortcuts
`modules/gcp-iam/main.tf` (lines 6–22) uses `locals` for lists it reuses:

```hcl
locals {
  gke_node_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    ...
  ]
}
```

`locals` are internal constants/expressions (not user-facing knobs). Reference them
as `local.gke_node_roles`. Great for DRY-ing up repeated values.

---

## 6. Interpolation, references, and the dependency graph (the "magic")

This is the concept that makes Terraform click. Look at the subnet
(`modules/gcp-networking/main.tf` lines 13–17):

```hcl
resource "google_compute_subnetwork" "databricks_subnet" {
  name    = "${var.network_name}-subnet-${var.environment}"
  network = google_compute_network.databricks_vpc.id   # <-- reference!
  ...
}
```

- `"${var.network_name}-subnet-${var.environment}"` is **string interpolation** —
  `${...}` injects a value. With `network_name=databricks-vpc` and `environment=dev`
  it produces `databricks-vpc-subnet-dev`.
- `google_compute_network.databricks_vpc.id` is a **cross-resource reference**. The
  subnet needs the VPC's id.

When one resource references another, Terraform builds an implicit **dependency
graph** and automatically creates them in the right order: VPC first, then subnet,
then router/NAT/firewalls. You never write "step 1, step 2" — Terraform derives
ordering from the references. That's the declarative model in action.

### When references aren't enough: `depends_on`
Sometimes A must come before B but B doesn't reference A. Then you state it
explicitly. `main.tf` (lines 97–100):

```hcl
module "databricks_workspace" {
  ...
  depends_on = [module.gcp_networking, module.gcp_iam]
}
```

This guarantees the network and IAM exist before Terraform asks Databricks to build
the workspace on top of them.

---

## 7. Modules — packaging infrastructure into reusable units

Instead of one giant file, this project is split into **modules** — self-contained
folders you can call like functions. Look at `main.tf` (lines 55–75):

```hcl
module "gcp_networking" {
  source       = "./modules/gcp-networking"   # where the module lives
  project_id   = var.gcp_project_id           # inputs passed in
  region       = var.gcp_region
  network_name = var.network_name
  ...
}
```

A module is just a folder with the same three file types you already know:

```
modules/gcp-networking/
├── main.tf        # the resources
├── variables.tf   # inputs the module accepts   (its "function parameters")
└── outputs.tf     # values it returns            (its "return values")
```

### How modules talk to each other: outputs → inputs
The networking module *returns* the VPC name via `outputs.tf` (lines 6–9):

```hcl
output "vpc_name" {
  value = google_compute_network.databricks_vpc.name
}
```

The root then *feeds that output into* the workspace module (`main.tf` line 90):

```hcl
module "databricks_workspace" {
  network_id = module.gcp_networking.vpc_name   # output of one → input of another
  subnet_id  = module.gcp_networking.subnet_name
  ...
}
```

`module.<name>.<output>` is how you wire modules together. This is exactly how the
networking layer, IAM layer, and workspace layer connect without any of them knowing
each other's internals. It's the software-engineering principle of *composition*
applied to infrastructure.

> Subtle but important detail in this project: the workspace wants the **bare name**
> (`vpc_name`, `subnet_name`), not the full self-link (`vpc_id`). Passing the wrong one
> is a classic Databricks-on-GCP failure — the outputs file exposes both so the root
> can pick correctly.

### Passing providers into a module
Modules don't automatically inherit aliased providers. `main.tf` (lines 80–83)
explicitly hands the workspace module the account-level Databricks provider:

```hcl
providers = {
  databricks = databricks.accounts
  google     = google
}
```

---

## 8. Meta-arguments — the "loops and settings" of Terraform

Meta-arguments are special arguments Terraform understands on *any* resource.

### `for_each` — create N copies from a collection
Rather than copy-pasting a role binding six times, `modules/gcp-iam/main.tf`
(lines 35–41) loops:

```hcl
resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset(local.gke_node_roles)   # a set of 6 role strings
  project  = var.project_id
  role     = each.value                    # the current role in the loop
  member   = "serviceAccount:${google_service_account.gke_node.email}"
}
```

This creates **one binding per role** — six resources from one block. Each instance is
tracked separately in state as `...gke_node_roles["roles/logging.logWriter"]` etc., so
adding/removing a role only touches that one binding. (The sibling of `for_each` is
`count = N`, used when you just need a numbered N copies.)

### `lifecycle` and safety guards
`modules/gcp-iam/main.tf` line 84 uses a plain expression as a guard rail:

```hcl
force_destroy = var.environment != "prod"   # true in dev, false in prod
```

In dev the DBFS bucket can be force-deleted (handy for teardown tests like the one you
ran); in prod Terraform will refuse to delete a non-empty bucket — a deliberate
safety brake.

### `timeouts` — for slow-to-provision resources
The workspace can take many minutes to build, so
`modules/databricks-workspace/main.tf` (lines 54–58) raises the limits:

```hcl
timeouts {
  create = "30m"
  read   = "10m"
  update = "20m"
}
```

Without this, Terraform's default timeout could fire before Databricks finishes.

---

## 9. Data sources & the state file

### Data sources — *read* existing things (don't create)
A `resource` creates; a `data` source **looks up** something that already exists.
`workspace_access.tf` (lines 9–12):

```hcl
data "databricks_user" "admin" {
  provider  = databricks.accounts
  user_name = var.workspace_admin_user   # supplied from your gitignored tfvars
}
```

This doesn't create a user — it fetches the existing account user so we can read its
`.id` and grant it workspace admin in the next resource (lines 15–20). Data sources
are how Terraform-managed resources reference things Terraform didn't create.

### State — Terraform's memory
After `apply`, Terraform writes `terraform.tfstate`: a JSON map of *every* resource it
manages and that resource's real-world IDs/attributes. This is how `plan` knows what
already exists.

Key things to internalize about state:

- **It's the source of truth for Terraform.** If you delete a resource by hand in the
  GCP console, Terraform doesn't know until the next `plan` (which will then offer to
  recreate it). Conversely, `terraform destroy` only destroys what's *in state*.
- **It can contain secrets.** State may hold sensitive values in plaintext. Never
  commit `terraform.tfstate` to git (this repo's `.gitignore` excludes it). For teams,
  store state in a **remote backend** (e.g. a GCS bucket) so everyone shares one state
  and it's locked during applies. This project uses local state, which is fine for one
  operator.
- **Useful state commands:** `terraform state list` (what's tracked),
  `terraform show` (full details), `terraform state rm` (forget a resource without
  destroying it).

That "state vs. reality" gap is exactly what bit us during teardown — see §10.

---

## 10. Techniques cheat-sheet (as used in THIS repo)

| Technique | Where | Why it matters |
|-----------|-------|----------------|
| `terraform {}` + `required_providers` with `~>` pins | `main.tf:6` | Reproducible provider versions |
| Aliased providers (`accounts` vs `workspace`) | `main.tf:37,45` | Talk to two endpoints of one provider |
| Env-var / ADC auth (no secrets in code) | `scripts/deploy.sh` | Safe to commit; secrets stay out of git |
| Input variables + `sensitive` + `validation` | `variables.tf` | Parameterize + protect + fail fast |
| `-var-file` per environment | `environments/dev\|prod` | One codebase, many environments |
| `locals` for DRY lists | `gcp-iam/main.tf:6` | Avoid repetition |
| String interpolation `${...}` | everywhere | Compose names like `databricks-vpc-dev` |
| Cross-resource references → auto dependency graph | `gcp-networking/main.tf:17` | Correct ordering for free |
| `depends_on` for hidden ordering | `main.tf:97` | Network/IAM before workspace |
| Modules + `output`→input wiring | `main.tf:55–101` | Composable, reusable layers |
| `for_each` over a `toset(...)` | `gcp-iam/main.tf:36,55` | N resources from one block |
| `lifecycle`/guard (`force_destroy`) | `gcp-iam/main.tf:84` | Prod safety brake |
| `timeouts` | `databricks-workspace/main.tf:54` | Handle slow provisioning |
| `data` source lookup | `workspace_access.tf:9` | Reference existing (non-TF) objects |
| `disable_on_destroy = false` on APIs | `gcp-iam/main.tf:141` | Don't disable shared project APIs on teardown |

### The one gotcha this project taught us: state vs. reality
When we ran `terraform destroy`, it reported success but the VPC deletion actually
**failed** — because Databricks had created untracked `db-*` firewall rules *inside*
our VPC that Terraform's state knew nothing about. Terraform can only delete what's in
its state; those orphan rules blocked the VPC delete. `scripts/teardown.sh` handles
this by detecting the leftover firewalls with `gcloud`, deleting them, and retrying
the destroy. **Lesson:** Terraform manages *its* resources; anything created
out-of-band (by another system or a human in the console) is invisible to it and can
trip you up. See the memory note `databricks-gcp-destroy-orphan-firewall` for details.

---

## 11. A mental model to keep

```
   variables.tf / *.tfvars     →  the KNOBS (what's configurable)
            │
            ▼
   resource / module blocks     →  the DESIRED STATE (what should exist)
            │  (references build a dependency graph)
            ▼
   terraform plan               →  diff desired-state vs. state file
            │
            ▼
   terraform apply              →  providers make API calls to GCP + Databricks
            │
            ▼
   terraform.tfstate            →  Terraform's memory of what it built
            │
            ▼
   outputs.tf                   →  the useful results (workspace_url, ids, …)
```

Everything you do in Terraform is somewhere in that pipeline.

---

## 12. Where to go next (suggested learning path)

1. **Read the plan before every apply.** Get fluent reading `+ / ~ / -` diffs — it's
   the single most valuable habit. Try `terraform plan` now (it should say "no changes"
   since everything is applied).
2. **Experiment safely in dev.** Change `subnet_cidr` in `dev.tfvars`, run `plan`, and
   watch Terraform want to replace the subnet — then revert. Reading a plan you *caused*
   is the fastest way to learn.
3. **Learn remote state** (GCS backend + locking) when more than one person or CI runs
   this. It's the main upgrade from this single-operator setup.
4. **Explore `terraform fmt`** (auto-format) and `terraform validate` (syntax/config
   check) — cheap, run-anytime hygiene commands.
5. **Official tutorials:** HashiCorp's "Get Started - Google Cloud" track mirrors
   almost everything above with runnable examples.

---

*Companion docs in this repo: `README.md` (overview), `DEPLOYMENT_GUIDE.md` (the
operational runbook incl. teardown quirk). This file focuses on the Terraform concepts
so you can read the real `.tf` files with confidence.*
