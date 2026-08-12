# Infrastructure (AWS CDK)

Route53 (optional) → ALB → ECS Fargate (autoscaling on CPU) → RDS Postgres +
ElastiCache Redis, all in one VPC. Follows `plans/aws.md`. Every account- or
size-specific knob lives in `config.json` — nothing is hardcoded in `lib/`, so
the same app deploys into any AWS account by editing that one file (or
pointing `CONFIG_PATH` at a different one per account/environment).

## What this does and doesn't manage

Owns: VPC, security groups, ECR repository, ECS cluster/service/task
definition + autoscaling, ALB, RDS instance, ElastiCache cluster, optional
Route53 record + ACM certificate.

Does **not** own: building/pushing the Docker image (a separate step, see
below), the `RAILS_MASTER_KEY` secret's value (must exist before deploy — see
below), or the domain/hosted zone itself (looked up by name, never created —
a hosted zone is $0.50/month forever, not something to spin up per deploy).

## Cost shape

Kept close to free-tier by default (`config.json`):

- **No NAT Gateway** (`vpc.natGateways: 0`) — Fargate tasks sit in public
  subnets with a public IP instead, which is enough to reach ECR/Secrets
  Manager/CloudWatch over the internet without paying ~$32/month + data
  processing for a NAT Gateway.
- **RDS**: `db.t4g.micro`, single-AZ, 20 GiB gp2 — matches the RDS free-tier
  allowance on a new account (first 12 months).
- **Redis**: `cache.t4g.micro`, single node, no replication — same free-tier
  shape on ElastiCache.
- **Fargate**: smallest task size (256 CPU units / 512 MiB), `minCapacity: 1`.
  Fargate itself has no free tier — this is the cheapest it gets, not free.
- **ALB**: also has no free tier, and is the one piece explicitly asked for
  in `plans/aws.md`. Its hourly charge plus Fargate are the two costs that
  don't disappear even at zero traffic.

Scale the two things that actually cost money — Fargate task count and
size — through `config.ecs`, not by editing the stack.

## Before the first deploy

1. **Bootstrap the target account** (once per account/region):
   ```bash
   npx cdk bootstrap
   ```
2. **Create the Rails master key secret.** The stack reads this secret, it
   never generates or overwrites it — a stack-generated placeholder would
   silently produce a container that can't decrypt `config/credentials.yml.enc`.
   ```bash
   aws secretsmanager create-secret \
     --name gwars/rails-master-key \
     --secret-string "$(cat ../config/master.key)"
   ```
   (Matches `config.secrets.railsMasterKeySecretName` in `config.json`.)
3. **Push an image to ECR** — the very first deploy needs something for the
   task definition to point at. Either deploy once to create the (empty)
   repository, push, then deploy again; or create the repository by hand
   first. Either way, pushing looks like:
   ```bash
   aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
   docker build -t gwars ..
   docker tag gwars:latest <account>.dkr.ecr.<region>.amazonaws.com/gwars:latest
   docker push <account>.dkr.ecr.<region>.amazonaws.com/gwars:latest
   ```

## Deploying

```bash
npm install
npm run deploy
```

To point at a domain already in Route53, fill in `config.json`'s `domain`
block (`hostedZoneName` + `subdomain`) before deploying — this adds an ACM
certificate (DNS-validated against that zone, free), an HTTPS listener with
an HTTP→HTTPS redirect, and a Route53 alias record. Leave both blank (the
default) and the ALB is reachable over plain HTTP on its own `*.elb.amazonaws.com`
name instead — nothing else about the stack changes.

To deploy the same app into a second account, copy `config.json`, adjust it,
and run with `CONFIG_PATH` pointed at the copy:

```bash
CONFIG_PATH=./config.staging.json npm run deploy
```

## Config reference (`config.json`)

| Key | Meaning |
|---|---|
| `ecr.repositoryName` / `createRepository` | Repository name; set `createRepository: false` to point at one that already exists instead of owning its lifecycle. |
| `ecs.minCapacity` / `maxCapacity` | Task count floor/ceiling for autoscaling. |
| `ecs.cpuTargetUtilizationPercent` | Target-tracking scaling target (default 80) — ECS scales out above it, in below it. |
| `ecs.cpu` / `memoryLimitMiB` | Fargate task size, in the same units the AWS API takes (256 = 0.25 vCPU). |
| `database.instanceType` | Bare instance type, e.g. `"t4g.micro"` — no `db.` prefix. |
| `redis.nodeType` | Full node type, e.g. `"cache.t4g.micro"`. |
| `domain.hostedZoneName` / `subdomain` | Leave blank to skip Route53/ACM entirely (see above). |

## What's still manual (see `plans/aws.md`)

- Migrations run from the container's own entrypoint (`bin/docker-entrypoint`
  → `db:prepare`) on every task start, not as a separate release step. Fine
  at `minCapacity: 1`; worth revisiting before running several tasks that
  might start close together.
- No CI/CD — building, tagging and pushing the image, then forcing a new
  ECS deployment, is still a manual `aws ecs update-service --force-new-deployment`
  away.
