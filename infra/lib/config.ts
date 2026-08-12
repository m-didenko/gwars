import * as fs from "fs";
import * as path from "path";

// Everything that might change between AWS accounts or over time lives here,
// not in the stack. To deploy the same app into a different account, copy
// this file, point CONFIG_PATH at the copy, and nothing in lib/ changes.
// Account/region are deliberately not here — those come from the AWS CLI
// profile CDK runs under (CDK_DEFAULT_ACCOUNT/CDK_DEFAULT_REGION), so this
// file never has to know which account it is being deployed into.
export interface GwarsConfig {
  appName: string;

  vpc: {
    maxAzs: number;
    // 0 by default: Fargate tasks sit in public subnets with a public IP
    // instead, which reaches the internet (and ECR) over the Internet
    // Gateway that public subnets already have — a NAT Gateway would cost
    // real money for a project with no users yet.
    natGateways: number;
  };

  ecr: {
    repositoryName: string;
    // false to deploy against a repository that already exists (e.g. shared
    // across environments) instead of having this stack own its lifecycle.
    createRepository: boolean;
    imageTag: string;
    maxImageCount: number;
  };

  ecs: {
    containerPort: number;
    cpu: number;
    memoryLimitMiB: number;
    minCapacity: number;
    maxCapacity: number;
    cpuTargetUtilizationPercent: number;
    healthCheckPath: string;
    healthCheckGracePeriodSeconds: number;
    logRetentionDays: number;
  };

  database: {
    // Bare instance type string, e.g. "t4g.micro" — fed straight into
    // ec2.InstanceType, no separate class/size fields to keep in sync.
    instanceType: string;
    allocatedStorageGiB: number;
    databaseName: string;
    backupRetentionDays: number;
    multiAz: boolean;
    deletionProtection: boolean;
  };

  redis: {
    nodeType: string;
    port: number;
  };

  secrets: {
    // Must already exist (see infra/README.md) — this stack reads it, it
    // does not create it, so a freshly-generated placeholder can never end
    // up wired into the task by accident.
    railsMasterKeySecretName: string;
  };

  domain: {
    // Leave both blank to skip Route53/ACM entirely and expose the ALB over
    // plain HTTP on its own DNS name — the default for an account with no
    // domain yet. Fill both in to get HTTPS plus a Route53 alias record.
    hostedZoneName: string;
    subdomain: string;
  };
}

export function loadConfig(): GwarsConfig {
  const configPath = process.env.CONFIG_PATH
    ? path.resolve(process.env.CONFIG_PATH)
    : path.join(__dirname, "..", "config.json");

  if (!fs.existsSync(configPath)) {
    throw new Error(`Config file not found: ${configPath}`);
  }

  return JSON.parse(fs.readFileSync(configPath, "utf8")) as GwarsConfig;
}
