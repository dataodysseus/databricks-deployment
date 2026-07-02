# Bootstrap layer — one-time landing zone (run as a project owner)

This provisions the prerequisites the **workload** deploy (`../`) assumes already exist:

- the **automation service account** (the identity CI runs as, and Databricks impersonates),
- its **IAM floor** (roleAdmin, projectIamAdmin, serviceAccountAdmin, serviceAccountUser,
  storage.admin, compute.admin, container.admin, serviceUsageAdmin),
- **impersonation** grants (SA-on-itself for CI OIDC; optional human admin for local runs),
- the **GitHub WIF** pool + provider, scoped to your GitHub owner.

## Why it's separate

The workload CI runs **as** the automation SA. An identity must never Terraform-manage its
own permissions — it self-locks on destroy and hits a chicken-and-egg on create. So the floor
lives here, owned by a different (owner) identity, in **its own state**. See
`../DEPLOYMENT_GUIDE.md` §6.

## When to use

- ✅ **New GCP project/account** → run this once, then deploy the workload.
- ❌ **Your existing/current dev project** → if its SA/WIF were created out-of-band and are
  already in place, do **not** apply this there (it would collide). This layer is for
  reproducing the setup elsewhere.

## Run it (as a Project Owner)

```bash
# 0. One-time: create the versioned state bucket (chicken-and-egg — TF can't hold
#    the bucket its own backend lives in). Reuse one bucket for both layers.
PROJECT="your-gcp-project-id"
BUCKET="databricks-tfstate-${PROJECT}"
gcloud storage buckets create "gs://${BUCKET}" --project="$PROJECT" \
  --location=us-central1 --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update "gs://${BUCKET}" --versioning

# 1. Fill in values
cp bootstrap.tfvars.example bootstrap.tfvars   # edit it (gitignored)

# 2. Apply (owner ADC: gcloud auth application-default login)
cd bootstrap
terraform init -backend-config="bucket=${BUCKET}" -backend-config="prefix=bootstrap"
terraform apply -var-file=bootstrap.tfvars

# 3. terraform output  -> paste GCP_* into GitHub Environment secrets
terraform output
```

Then do the **manual, un-automatable** step (printed in `next_steps`): add the SA as an
**Account Admin** in the Databricks console, add the 5 GitHub secrets
(`GCP_PROJECT_ID`, `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_SERVICE_ACCOUNT`,
`DATABRICKS_ACCOUNT_ID`, `DATABRICKS_ADMIN_USER`), and run the workload Action.

## Teardown

Per project decommission, **delete the GCP project** — that removes the SA, all bindings,
WIF, and APIs in one shot. Don't surgically remove the floor (that's the risky self-lockout
path). If you must keep the project but drop the bootstrap, run `terraform destroy` here **as
an owner** (never as the automation SA).
