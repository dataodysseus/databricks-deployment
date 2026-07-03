# Deploying Databricks on Google Cloud with Terraform — a Reproducible, End-to-End Guide

*A two-part, hands-on walkthrough: from your first nervous `terraform plan` on a laptop to a fully automated, GitHub Actions–driven pipeline that builds and tears down a Databricks workspace on demand.*

---

# Part 1 — From Zero to a Working Deployment

## Why I bothered writing this down

I've read a lot of "deploy Databricks on GCP" tutorials, and almost all of them stop at the same place: a triumphant screenshot of a running workspace. Roll credits. The trouble is, that screenshot is the easy 20%. The part nobody shows you is the other 80% — making the thing *reproducible*. Can you destroy it on a Friday and rebuild it on Monday without sweating? Can you hand it to a teammate? Can you stand the whole stack up again in a fresh cloud project six months from now, when you've forgotten every gotcha you're about to learn?

That gap is what this series is about. I went through the whole arc — laptop clicks, a working workspace, then the slow grind of turning it into something a robot could run — and I took notes the entire way, including the moment I locked my own automation out of its own house (we'll get there). Part 1 gets you to a working workspace from your own machine. Part 2 removes *you* from the loop entirely.

One housekeeping note: this is all grounded in a real, working repository, but I've kept the actual identifiers — project IDs, account IDs, emails — out of the article. They live in secrets and gitignored files, never in the code. The commands and structure, though, are exactly what I ran.

## 1. The basics of Terraform (in five minutes)

If you've never touched Terraform, let me save you the week I spent circling it before it clicked. Terraform is **declarative infrastructure-as-code**. That's a mouthful, but the idea is simple: instead of clicking through a console or memorizing a sequence of CLI commands, you *write down the end state you want*, and Terraform works out the steps to get there. You describe the destination; it plots the route.

Four ideas carry almost all the weight, and once they land, the rest is detail.

**Providers** are plugins that teach Terraform how to talk to a particular platform's API. This deployment leans on two at once — the `google` provider for GCP (VPCs, subnets, service accounts, buckets) and the `databricks` provider for the account and workspace resources. You pin their versions, which is the boring habit that means a deployment working today still works next year instead of mysteriously breaking on some upstream change.

**Resources** are the individual things you want to exist: one VPC, one subnet, one workspace, one bucket. Each resource block is basically a noun with settings — "I want this to exist, configured like so." Terraform reads all your blocks, looks at what's actually out there, and quietly reconciles the difference.

**State** is Terraform's memory, and it's the concept I'd tattoo on a new engineer's hand. After Terraform creates something, it writes down the real-world ID in a state file, so next time it knows "I already built that VPC — leave it alone." Respect state and Terraform is a joy. Lose it or corrupt it and Terraform develops amnesia about everything it owns. (In Part 2 we move state off the laptop into a shared, versioned bucket — that one move is what makes teams and CI possible at all.)

**The dependency graph** is the bit that genuinely delighted me. You never order your resources by hand. When one resource references another — the workspace needs the network's ID, the NAT needs the router — Terraform reads those references, builds a graph, and creates everything in the right order, in parallel wherever it safely can. You write *what* depends on *what*; Terraform figures out *when*.

Round it out with three commands and you know enough to be dangerous: `terraform init` (fetch providers, connect the backend), `terraform plan` (a dry run — *show me what would change and change absolutely nothing*), and `terraform apply` (actually do it). Running `plan` before `apply`, every single time, is the one habit that has saved me from myself more than any other.

## 2. Prerequisites — the parts you gather before any code runs

Here's a thing about Databricks-on-GCP: a handful of prerequisites are completely invisible until the exact moment an error message introduces you to them. Lining them up front is the difference between a smooth afternoon and a game of whack-a-mole with 403s.

**Your Databricks Account ID.** Databricks on GCP is *account-based* — a workspace is created under a Databricks **account**, and Terraform needs that account's ID to know where to put things. You find it by signing in to the account console at `accounts.gcp.databricks.com`, opening the user menu in the top-right, and copying the **Account ID** (a UUID). Treat it as sensitive from the start; in the repo it's flagged `sensitive = true` so it never lands in a log or a commit.

**A GCP project with billing enabled.** Everything lands inside one project. A Databricks free trial is perfect for following along — just keep one eye on the clock, because the trial burns while a workspace is running. (Which is exactly why Part 2 has a one-click teardown, and why this article has a whole cleanup section. Foreshadowing.)

**The GCP IAM roles Terraform needs.** This is where the most people get stuck, so let me be specific. To stand up the full stack, whoever runs Terraform needs enough authority to create networks, service accounts, IAM bindings, and buckets. For a personal project, `roles/owner` (or `roles/editor`) gets you moving. For the grown-up version we build toward in Part 2, a dedicated service account gets a tight "floor" of exactly what it needs: `compute.admin` for the network layer, `iam.serviceAccountAdmin` and `resourcemanager.projectIamAdmin` to create and bind the workspace's service accounts, `storage.admin` for the DBFS and state buckets, `container.admin` (Databricks runs on GKE under the hood — surprise), and `serviceusage.serviceUsageAdmin` to turn APIs on. The exact list matters less than the principle: name the powers explicitly, so the whole thing is reproducible instead of relying on your account happening to be all-powerful.

**The one step no API can do for you.** For Terraform's Databricks provider to authenticate at the account level, the identity it uses has to be a **Databricks Account Admin** — and there is no GCP or Terraform API to grant that. You add it by hand, in the Databricks account console. I'm flagging it loudly and early because every "fully automated" pipeline secretly has this one manual click in it, and pretending otherwise just produces baffling auth failures at the worst moment.

**The required APIs.** Compute, IAM, Cloud Storage, GKE/Container, and Service Usage all need enabling on the project. A small bootstrap script (or the bootstrap Terraform layer from Part 2) flips them all on at once, so you don't get to meet each one individually via its own error.

## 3. Terraform specifics for a Databricks deployment

A Databricks-on-GCP workspace isn't a single resource you conjure — it's a small system, and once you can picture the pieces, the code reads like a sentence.

The deployment uses the **customer-managed VPC** pattern, which is a fancy way of saying: instead of letting Databricks build its own network, *you* build the network and hand it the keys. That means a **VPC** with a **subnet**, and — because the workspace secretly runs on GKE — the subnet carries **two secondary IP ranges**, one for Kubernetes pods and one for services. A **Cloud Router** plus **Cloud NAT** lets the private cluster nodes reach the internet to pull libraries from PyPI and Maven without ever getting public IPs. Two **firewall rules** allow internal traffic and the Databricks control-plane ingress. Two **service accounts** back the workload, and a **GCS bucket** with versioning becomes the DBFS root.

On the Databricks side, three resources tie the bow: `databricks_mws_networks` registers your VPC and subnet with Databricks, `databricks_mws_workspaces` creates the actual workspace (this is the slow one — 15 to 25 minutes while GKE yawns and stretches into existence), and `databricks_mws_permission_assignment` grants your admin user access.

Two design choices are worth burning into memory. First, the code is split into **modules** — `gcp-networking`, `gcp-iam`, and `databricks-workspace` — so each concern is a self-contained folder with its own inputs and outputs, and the root module is just the wiring diagram. Second, environment-specific values live in **`.tfvars` files** (`dev.tfvars`, `prod.tfvars`), so the same code deploys dev, test, or prod by swapping a single file. And a gotcha that personally cost me an evening: `databricks_mws_networks` wants the VPC and subnet as **bare names** (`databricks-vpc-dev`), *not* GCP self-link URLs. Hand it the wrong form and it fails in a way the error message is in no hurry to explain.

## The architecture, in one picture

Words are fine, but I didn't really *get* this stack until I sketched it. Here's the whole thing on one screen — a customer-managed VPC in your GCP project, talking to the Databricks control plane over HTTPS:

```
┌──────────────────────────────────────────────────────────────┐
│  GCP Project: <your-project>                                   │
│                                                                │
│  ┌────────────────────────────────────────────────────────┐   │
│  │  VPC: databricks-vpc-dev                               │   │
│  │                                                        │   │
│  │  ┌──────────────────────────────────────────────────┐  │   │
│  │  │  Subnet  (primary range)                         │  │   │
│  │  │   ├── secondary range: GKE pods                  │  │   │
│  │  │   └── secondary range: GKE services              │  │   │
│  │  │                                                  │  │   │
│  │  │   ┌────────────────────────────────────────┐     │  │   │
│  │  │   │  GKE cluster (Databricks-managed)      │     │  │   │
│  │  │   │  private nodes · this is your workspace│     │  │   │
│  │  │   └────────────────────────────────────────┘     │  │   │
│  │  └──────────────────────────────────────────────────┘  │   │
│  │                                                        │   │
│  │   Cloud Router → Cloud NAT ──► internet (PyPI, Maven)  │   │
│  │   Firewall: internal + control-plane ingress          │   │
│  └────────────────────────────────────────────────────────┘   │
│                                                                │
│  2× Service Accounts   ·   GCS bucket (DBFS root, versioned)   │
└──────────────────────────────────────────────────────────────┘
                              │
                              │  HTTPS
                              ▼
              ┌──────────────────────────────────┐
              │  Databricks Control Plane        │
              │  accounts.gcp.databricks.com     │
              │  (your Databricks account)       │
              └──────────────────────────────────┘
```

Read it top to bottom and the earlier sections snap into place: the two secondary ranges exist *because* there's a GKE cluster in there; the NAT exists *because* those nodes are private but still need PyPI; the `mws_networks` resource is the arrow — the handshake where your VPC gets registered with the control plane. Everything above the dashed HTTPS line lives in *your* project and gets built by Terraform. Everything below it is Databricks' world, reached through that one account you made an admin in Section 2.

And that Cloud NAT deserves a sentence, because it's the piece people question when they see the bill. The GKE nodes are deliberately **private** — no public IPs, which is the security payoff of the customer-managed VPC. But private nodes still have to reach *out* to install libraries and phone the control plane, and a machine with no public IP can't do that on its own. Cloud NAT is the one-way door: egress to the internet, zero ingress from it. So it isn't optional plumbing — it's the thing that lets you have private nodes *and* a working `pip install`. You're paying for a security posture, not a luxury.

## A word on the network ranges — yes, you get to choose

When I first ran this, I didn't hand Terraform a single IP range and it worked fine — which raises a fair question: were those chosen *for* me, and would an enterprise get the same freedom? The answer is that nothing was hardcoded. The subnet and the two secondary ranges are plain Terraform **variables** — `subnet_cidr`, `pod_cidr`, `svc_cidr` — that simply ship with sensible defaults (`10.0.0.0/16` for the subnet, `10.1.0.0/16` for pods, `10.2.0.0/20` for services). On a fresh project with nothing else around, those defaults don't collide with anything, so it "just works" and you never think about it.

In an enterprise, you almost always *will* think about it — and you should. The ranges are yours to set; you override those three variables in your `.tfvars` and you're done. What changes is that you now have real constraints to respect: the ranges must be **private (RFC 1918)** and **must not overlap** with anything you peer or connect to — other VPCs, on-prem networks over VPN/Interconnect, or shared services — because overlapping CIDRs are the classic, painful networking outage. They also have to be **big enough for scale**: because the workspace runs on GKE, the *pods* secondary range especially has to accommodate a lot of addresses (roughly nodes × pods-per-node), and Databricks publishes a sizing table mapping workspace size to the minimum CIDR you should give each range. The short version: the defaults are a convenience for a greenfield demo, not a limitation — in a real deployment you plan the address space with your network team and pass it in, exactly the same way, through those variables.

## 4. Testing locally from VS Code

Before you automate a single thing, prove it works from your own machine. That tight, slightly nerve-wracking loop — edit, plan, apply, stare at the output — is where you actually learn the system, and it's a lot cheaper to learn there than inside a CI log.

Local authentication runs on **Application Default Credentials (ADC)**. You log in once with `gcloud auth login` for the CLI, then `gcloud auth application-default login` to hand Terraform its own credentials, and `gcloud config set project <your-project>` to aim everything at the right place. The Databricks provider rides on the same Google identity to reach the account console — which is precisely why the account-admin step from Section 2 has to be done, or this is where you'll find out it wasn't.

From there it's the three commands from Section 1, with a `-var-file` to pick the environment:

```bash
terraform init
terraform plan  -var-file=environments/dev/dev.tfvars
terraform apply -var-file=environments/dev/dev.tfvars
```

That first `plan` on an empty project prints something like "32 to add, 0 to change, 0 to destroy." Read it like a receipt before you pay — it's the last cheap moment before anything real happens. Then `apply` builds the stack, and most of the wall-clock time is just GKE coming up inside the workspace resource, so go make coffee. When it finishes, `terraform output workspace_url` prints the URL and you can log straight in — and there's a genuinely satisfying little jolt the first time your own workspace loads.

Doing this from VS Code with the Terraform extension is the move: syntax highlighting, inline validation, and a terminal in the same window, so you tweak a `.tfvars` value, re-plan, and watch the graph shift. And when you're done poking around, `terraform destroy -var-file=environments/dev/dev.tfvars` takes it all back down. Being able to destroy and rebuild cleanly, on your own machine, is the exact confidence you need before you hand the keys to a robot — which, at long last, is what Part 2 is all about.

---

# Part 2 — From "Works on My Machine" to a Real Pipeline

In Part 1 we built a Databricks workspace by hand from a laptop. That's reproducible-*ish* — but honestly it depends on *my* gcloud login, *my* ADC, *my* local state file sitting in a folder somewhere. If I got hit by a bus, so did the deployment. Part 2 fixes that by removing *me* from the loop entirely: keyless authentication, shared state, a workflow with a friendly dropdown, and a repo laid out so dev, test, and prod all flow through the same code. By the end, deploying or destroying a workspace is a single click in GitHub, and anyone with the right access can pull the lever.

## 1. GitHub OIDC — killing the service-account key

The very first instinct when you automate a cloud deploy is to export a service-account JSON key, paste it into a GitHub secret, and move on with your life. Please don't. A long-lived key sitting in a CI system is the single most common way clouds get popped — it never expires, and the day it leaks (a log, a fork, a screen-share), it's game over and you won't even know when it happened.

The modern answer is **Workload Identity Federation (WIF)**, GitHub's OIDC integration with GCP, and the first time I set it up I actually laughed at how much better it is. Here's the trick: on every workflow run, GitHub mints a **short-lived OIDC token** that basically says "this is a genuine run, from this repo." GCP is configured to *trust* those tokens and swap them for temporary credentials that impersonate an automation service account. No key is ever created, stored, or exported. The credential lives for minutes and is scoped to that one run. Nothing to leak.

You wire this up once with three pieces: a **Workload Identity Pool**, a **provider** inside it that trusts GitHub's OIDC issuer, and an **IAM binding** that lets tokens from your repos impersonate the service account. My favorite touch is scoping the provider with an **attribute condition** — I used `assertion.repository_owner == '<my-github-owner>'`, which means *any* repo under my GitHub account can authenticate, so I never have to go back and reconfigure GCP each time I spin up a new one. In the workflow, the whole dance collapses to a single step: `google-github-actions/auth@v2` takes the OIDC token and hands back usable credentials. From there, Terraform's Google provider and the Databricks provider (which mints a Google ID token to reach the account console) both just work — keylessly, quietly, no secrets on disk.

## 2. A repo that scales to dev / test / prod

Automation is only ever as good as the structure underneath it, and two decisions are what let one repository serve three environments without turning into spaghetti.

**Remote, shared, per-environment state.** The cozy local state file from Part 1 simply can't survive CI — runners are ephemeral, and if two people ran at once they'd trample each other's state into paste. So state moves to a **versioned GCS bucket**. The clever bit is a **partial backend**: the code declares `backend "gcs" {}` with *no* bucket or prefix baked in, and both are supplied at `init` time. That keeps project-specific values out of committed code, and — crucially — a per-environment **prefix** (`databricks/dev`, `databricks/test`, `databricks/prod`) walls each environment's state off inside the same bucket. Versioning buys you state recovery when something goes sideways; GCS's built-in locking stops two runs from racing into the same file.

**Two layers, two identities.** This is the design decision I'm quietly proudest of, and — full disclosure — it was born from a bug that made me feel very stupid for an afternoon (Section 5, I promise). The repo has a **bootstrap** layer and a **workload** layer, deliberately owned by *different* identities. The bootstrap layer (`bootstrap/`) is run once per project *by a human owner*; it creates the automation service account, its IAM floor, and the WIF pool. The workload layer (the root module) runs on *every* deploy, *as* the automation service account. They keep separate state (different prefixes) so their lifecycles never collide. And the golden rule that falls out of all this — the one sentence I'd frame — is: **an identity must never Terraform-manage its own permissions.**

**Config lives in two clearly separated places.** Sensitive, per-environment values — project ID, WIF provider, service account, Databricks account ID, admin user — live as **GitHub Environment secrets**. Scoping them to a GitHub *Environment* has a lovely side effect: you get required-reviewer protection on prod for free. Non-sensitive run-time choices — which environment, plan vs apply vs destroy, the region, the workspace name — come from **workflow dropdown inputs**. Real `.tfvars` and `backend.hcl` files are gitignored; only `*.example` templates get committed. My repo is public, so *no* real identifier ever touches the code — and honestly that's a discipline worth keeping even when nobody's watching.

## 3. The GitHub Action

There are two workflows, and they have very different jobs — one is the nervous gatekeeper, the other is the big red button.

**The validate workflow** is the gatekeeper. It runs automatically on every push and pull request that touches a `.tf` file, running `terraform fmt -check` and `terraform validate` on both the workload and bootstrap roots. The elegant part: it uses `-backend=false`, so it needs **no credentials** and physically *cannot* touch cloud state. It just checks syntax, references, types, and provider schemas — a fast, safe correctness gate that catches the dumb stuff before it ever gets near an apply. It's saved me from pushing a broken reference more times than I'd like to admit.

**The deploy workflow** is the big red button, and it's the star of the show. It's a manual `workflow_dispatch` with four dropdown inputs: `environment` (dev/test/prod), `action` (plan/apply/destroy), `region`, and an optional `workspace_name` (leave it blank and it defaults to `databricks-gcp-<env>`). The `environment` you pick decides which set of Environment secrets loads — that's the whole trick to one workflow safely serving three environments. Under the hood the job authenticates via WIF, sets up gcloud and a pinned Terraform version, runs `init` with the per-environment backend config, then validates, plans, and — depending on the action you chose — applies or destroys. Sensitive values arrive as `TF_VAR_*` environment variables sourced from secrets, so nothing sensitive ever gets written to disk or spilled into a log.

Two production niceties earned their keep. **Concurrency control plus state locking** stop two runs from stepping on the same environment mid-flight. And the destroy path has **automatic orphaned-firewall cleanup** — because Databricks leaves behind untracked `db-*` firewall rules that stubbornly block the VPC's deletion, so the destroy step retries a few times, sweeping up those stragglers between attempts. That one unglamorous piece of automation is the entire difference between "destroy works if you babysit it" and "destroy works while you're at lunch."

## 4. Reproduce it from the repo — the steps your readers follow

Enough theory — here's the actual path, start to finish, if you want to run this yourself.

**For a brand-new GCP project, run the bootstrap layer once, as an owner.** There's a genuine chicken-and-egg here — Terraform can't hold the very bucket its own backend lives in — so you create the state bucket by hand first:

```bash
gcloud storage buckets create gs://databricks-tfstate-<project> \
  --location=us-central1 --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://databricks-tfstate-<project> --versioning
```

Then provision the service account, IAM floor, and WIF:

```bash
cd bootstrap
cp bootstrap.tfvars.example bootstrap.tfvars   # fill in your values (gitignored)
terraform init -backend-config="bucket=databricks-tfstate-<project>" \
               -backend-config="prefix=bootstrap"
terraform apply -var-file=bootstrap.tfvars
terraform output    # prints the GCP_* values you'll paste into GitHub secrets
```

**Do the one manual step.** In the Databricks account console, add the automation service account as an **Account Admin**. No API can do this for you, and skipping it is the single most common reason a first deploy fails to authenticate. (Told you it'd come back.)

**Set the five GitHub Environment secrets** — `GCP_PROJECT_ID`, `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT`, `DATABRICKS_ACCOUNT_ID`, `DATABRICKS_ADMIN_USER` — under a GitHub Environment named for each target (dev/test/prod).

**Deploy from the Actions tab.** Open the "Deploy Databricks Workspace" workflow, choose `environment: dev` and `action: plan`, and run it. Read the plan (a fresh build shows ~32 resources to add). Happy? Run it again with `action: apply`. Fifteen-ish minutes later the job summary prints your workspace URL, and you're in. Same building, brand-new keys, and you never touched a JSON credential.

## 5. Cleanup — because the trial clock is always running

Here's the section most tutorials skip, and it's the one that saves you actual money. A live Databricks workspace is a running GKE cluster, a NAT, buckets, the works — and if you're on a free trial, the meter is ticking the whole time it's up. So build teardown into the muscle memory, not the afterthought.

**Tearing down a workspace** is exactly as easy as building one: the same deploy workflow, `action: destroy`. That orphaned-firewall cleanup from Section 3 means it runs unattended — no babysitting, no manual "why won't the VPC delete" detour at 11pm. Locally, it's the mirror of the apply: `terraform destroy -var-file=environments/dev/dev.tfvars`. Either way, everything Terraform built, Terraform removes.

**Decommissioning an entire project** is a different question, and the answer surprised me: **just delete the GCP project.** That removes the service account, every IAM binding, the WIF pool, and all the enabled APIs *atomically*, in one clean stroke. It's dramatically safer than trying to surgically un-grant roles one at a time — and, as the next section explains with some embarrassment, "surgical role removal" is precisely the trap that once locked my automation out of its own house. When you're truly done with an environment, don't tidy it; delete the project and let GCP garbage-collect the whole thing.

A couple of habits that keep the bill honest: destroy dev workspaces at the end of a work session rather than letting them idle overnight; keep an eye on the DBU meter, since compute is the real cost, not the plumbing; and if you're just demoing, treat "spin up in the morning, destroy by evening" as the default rhythm. The entire point of a one-click teardown is that leaving something running should feel like a *choice*, not an accident.

## 6. What does it actually cost?

Here's a number that trips everyone up: the deployment stands up **32 resources**, and the natural assumption is "32 things to pay for." The reality is much friendlier — roughly a third of them cost *nothing*, and the whole bill really comes down to about five items. Once you see it that way, the cost model stops being scary.

Start with the free stuff, because there's a lot of it. The VPC, the subnet and its two secondary ranges, the Cloud Router, both firewall rules, both service accounts, every IAM binding, the API enablements, and the Databricks-side registration resources (`databricks_mws_networks` and `databricks_mws_permission_assignment`) — all **$0**. That's the majority of the 32. They're plumbing: they define *how* things connect and *who* can do *what*, but they don't run anything.

The money hides in a much shorter list:

| What actually costs money | When it bills | Rough cost (us-central1) |
|---|---|---|
| **Cloud NAT** gateway | always, while it exists | ~$32/mo + ~$0.045/GB processed |
| **GCS bucket** (DBFS root) storage | always | a few $/mo when idle |
| **GKE cluster management fee** (the workspace runs on GKE) | always, while the workspace exists | ~$0.10/hr (~$73/mo) |
| **GKE baseline node VMs** (system pods) | always, even with zero jobs | ~$100–200/mo idle |
| **DBUs** — Databricks license units | only while *your* clusters run | ~$0.22–0.55/DBU · $0 when idle |
| **Job/cluster node VMs** | only while *your* clusters run | standard GCE compute rates |

The single most important thing to internalize — and the bit most tutorials quietly omit — is that a Databricks-on-GCP workspace is **not** a serverless "$0 when idle" service. `databricks_mws_workspaces` looks like one line of Terraform, but behind it sits a real, always-on GKE cluster, and that cluster bills whether or not anyone ever opens a notebook. So there's an **idle floor** of roughly **$200–300/month** — Cloud NAT, the GKE management fee, the baseline nodes, and a little bucket storage — that exists purely for the workspace to *be there*.

On top of that floor sits the **variable** cost: DBUs plus the compute VMs of whatever clusters you actually spin up. That part genuinely does drop to near-zero when every cluster is terminated — but the floor does not. This is the whole reason the one-click **destroy** from the last section matters so much on a free trial: idling a workspace overnight isn't free, and the meter you can't see (the GKE cluster) is the one doing the damage.

One question that comes up immediately: *which account gets billed?* Think of it as two meters, not two invoices. The **GCP infrastructure** — the VPC, Cloud NAT, the GKE cluster and all node VMs, bucket storage, egress — bills to your **GCP account**; the machines are yours. The **DBUs** — Databricks' license units for the software layer running on top — are billed by **Databricks**, but on GCP that billing usually flows *through* the GCP Marketplace, so it often lands on your GCP invoice as a Databricks line item rather than a separate charge. The mental model that matters: when a cluster runs you pay *both* meters at once (the VM **and** the DBU on top of it); terminate the cluster and both stop; the idle floor keeps ticking on the GCP side until you `destroy`. (Every figure here is order-of-magnitude and moves with region, tier, and usage — confirm against the live pricing pages before you quote it.)

## 7. The lesson that shaped the whole design

Let me close with the bug that taught me the most, because the fix genuinely *became* the architecture. Originally — and it seemed so reasonable at the time — the workload Terraform granted the automation service account its own bootstrap roles. Convenient. Worked perfectly on my laptop. Then the first CI `destroy` ran, and it failed in the most poetic way imaginable.

Because CI runs *as* that service account, `destroy` cheerfully removed the SA's `projectIamAdmin` role partway through — and with that role gone, it could no longer edit IAM to delete its own final binding. `403 Policy update access denied`. The automation had, very politely, locked itself out of the house while walking out the front door and pulling it shut. I stared at that log for a while.

The fix wasn't a patch, it was a redesign: move every "grant the SA its powers" resource out of the workload and into the owner-run bootstrap layer. The workload SA now manages the *workload* and never so much as glances at its own permissions. That's the entire reason for the two-layer, two-identity split — and it generalizes far past Databricks. **Terraform should manage the workload, never the hands that run it.** Internalize that one sentence and you'll sidestep a whole genre of self-inflicted CI outages that I had to earn the hard way.

---

*The complete, runnable repository — with a Terraform primer, a full deployment runbook, and this CI/CD documentation — is public on GitHub. Clone it, wire up your own secrets, and you should have a workspace of your own inside half an hour. If you hit a snag reproducing it, the troubleshooting sections in the repo's deployment guide cover the errors I actually ran into, in the order I actually ran into them. Good luck — and remember to destroy it when you're done.*
