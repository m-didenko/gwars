import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as ecsPatterns from "aws-cdk-lib/aws-ecs-patterns";
import * as ecr from "aws-cdk-lib/aws-ecr";
import * as rds from "aws-cdk-lib/aws-rds";
import * as elasticache from "aws-cdk-lib/aws-elasticache";
import * as elbv2 from "aws-cdk-lib/aws-elasticloadbalancingv2";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as route53 from "aws-cdk-lib/aws-route53";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as logs from "aws-cdk-lib/aws-logs";
import { GwarsConfig } from "./config";

export interface GwarsStackProps extends cdk.StackProps {
  config: GwarsConfig;
}

export class GwarsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: GwarsStackProps) {
    super(scope, id, props);

    const { config } = props;

    // ---------------------------------------------------------------------
    // Network. No NAT Gateway (see config.vpc.natGateways) — Fargate tasks
    // run in the public subnets instead, RDS and Redis in isolated ones.
    // Isolated subnets still route to the public ones inside the VPC, they
    // just have no route out to the internet, which is all they need: only
    // the app talks to them, never the other way around.
    // ---------------------------------------------------------------------
    const vpc = new ec2.Vpc(this, "Vpc", {
      maxAzs: config.vpc.maxAzs,
      natGateways: config.vpc.natGateways,
      subnetConfiguration: [
        { name: "public", subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        {
          name: "data",
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
          cidrMask: 24,
        },
      ],
    });

    // ---------------------------------------------------------------------
    // ECR — where the image built by the repo's own Dockerfile gets pushed.
    // Pushing the image itself is a separate step (see infra/README.md);
    // this stack only owns the repository, not the build.
    // ---------------------------------------------------------------------
    const repository = config.ecr.createRepository
      ? new ecr.Repository(this, "Repository", {
          repositoryName: config.ecr.repositoryName,
          lifecycleRules: [{ maxImageCount: config.ecr.maxImageCount }],
          removalPolicy: cdk.RemovalPolicy.DESTROY,
          emptyOnDelete: true,
        })
      : ecr.Repository.fromRepositoryName(
          this,
          "Repository",
          config.ecr.repositoryName
        );

    // ---------------------------------------------------------------------
    // Secrets. The master key must already exist (a stack that generated it
    // would deploy a working-looking secret nobody can actually decrypt
    // credentials with) — everything else (DB credentials) is generated
    // fresh by RDS and never touched by hand.
    // ---------------------------------------------------------------------
    const railsMasterKey = secretsmanager.Secret.fromSecretNameV2(
      this,
      "RailsMasterKey",
      config.secrets.railsMasterKeySecretName
    );

    // ---------------------------------------------------------------------
    // Security groups. Only the app can reach the database or Redis; only
    // the load balancer can reach the app.
    // ---------------------------------------------------------------------
    const albSecurityGroup = new ec2.SecurityGroup(this, "AlbSecurityGroup", {
      vpc,
      description: "Load balancer: open to the internet on the web ports",
      allowAllOutbound: true,
    });
    albSecurityGroup.addIngressRule(
      ec2.Peer.anyIpv4(),
      ec2.Port.tcp(80),
      "HTTP"
    );

    const serviceSecurityGroup = new ec2.SecurityGroup(
      this,
      "ServiceSecurityGroup",
      {
        vpc,
        description: "Fargate service: reachable only from the load balancer",
        allowAllOutbound: true,
      }
    );

    const databaseSecurityGroup = new ec2.SecurityGroup(
      this,
      "DatabaseSecurityGroup",
      {
        vpc,
        description: "Postgres: reachable only from the Fargate service",
        allowAllOutbound: false,
      }
    );
    databaseSecurityGroup.addIngressRule(
      serviceSecurityGroup,
      ec2.Port.tcp(5432),
      "From the app"
    );

    const redisSecurityGroup = new ec2.SecurityGroup(
      this,
      "RedisSecurityGroup",
      {
        vpc,
        description: "Redis: reachable only from the Fargate service",
        allowAllOutbound: false,
      }
    );
    redisSecurityGroup.addIngressRule(
      serviceSecurityGroup,
      ec2.Port.tcp(config.redis.port),
      "From the app"
    );

    // ---------------------------------------------------------------------
    // RDS — single-AZ Postgres sized for the free tier by default
    // (config.database.instanceType). No Multi-AZ, minimal backup
    // retention: there are no players yet, this is not the moment to pay
    // for redundancy nobody depends on.
    // ---------------------------------------------------------------------
    const database = new rds.DatabaseInstance(this, "Database", {
      engine: rds.DatabaseInstanceEngine.postgres({
        version: rds.PostgresEngineVersion.VER_16,
      }),
      instanceType: new ec2.InstanceType(config.database.instanceType),
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_ISOLATED },
      securityGroups: [databaseSecurityGroup],
      credentials: rds.Credentials.fromGeneratedSecret("gwars_admin"),
      databaseName: config.database.databaseName,
      allocatedStorage: config.database.allocatedStorageGiB,
      storageType: rds.StorageType.GP2,
      storageEncrypted: true, // free — AWS-managed key, no extra cost
      multiAz: config.database.multiAz,
      backupRetention: cdk.Duration.days(config.database.backupRetentionDays),
      deletionProtection: config.database.deletionProtection,
      removalPolicy: config.database.deletionProtection
        ? cdk.RemovalPolicy.RETAIN
        : cdk.RemovalPolicy.DESTROY,
      publiclyAccessible: false,
    });

    // ---------------------------------------------------------------------
    // ElastiCache — no L2 construct in the CDK for this, so it's the Cfn
    // resources directly. A single node, no replication: Action Cable
    // broadcasts are transient, losing them on a node replacement just
    // means a client re-syncs over GET /battles/:id/state like it already
    // does after any dropped websocket.
    // ---------------------------------------------------------------------
    const redisSubnetGroup = new elasticache.CfnSubnetGroup(
      this,
      "RedisSubnetGroup",
      {
        description: "Isolated subnets, same as the database",
        subnetIds: vpc.selectSubnets({
          subnetType: ec2.SubnetType.PRIVATE_ISOLATED,
        }).subnetIds,
      }
    );

    const redis = new elasticache.CfnCacheCluster(this, "Redis", {
      engine: "redis",
      cacheNodeType: config.redis.nodeType,
      numCacheNodes: 1,
      port: config.redis.port,
      cacheSubnetGroupName: redisSubnetGroup.ref,
      vpcSecurityGroupIds: [redisSecurityGroup.securityGroupId],
    });

    // ---------------------------------------------------------------------
    // Domain + certificate. Both optional — with no hostedZoneName the ALB
    // is reachable over plain HTTP on its own DNS name, which is enough
    // for an account with no domain yet.
    // ---------------------------------------------------------------------
    let certificate: acm.ICertificate | undefined;
    let domainZone: route53.IHostedZone | undefined;
    let domainName: string | undefined;

    if (config.domain.hostedZoneName) {
      domainZone = route53.HostedZone.fromLookup(this, "HostedZone", {
        domainName: config.domain.hostedZoneName,
      });
      domainName = config.domain.subdomain
        ? `${config.domain.subdomain}.${config.domain.hostedZoneName}`
        : config.domain.hostedZoneName;

      certificate = new acm.Certificate(this, "Certificate", {
        domainName,
        validation: acm.CertificateValidation.fromDns(domainZone),
      });
    }

    // ---------------------------------------------------------------------
    // The service itself. ecsPatterns wires up the ALB, listener, target
    // group and service together; everything below just fills in what's
    // specific to this app.
    // ---------------------------------------------------------------------
    const logGroup = new logs.LogGroup(this, "ServiceLogs", {
      retention: config.ecs.logRetentionDays as logs.RetentionDays,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const fargateService = new ecsPatterns.ApplicationLoadBalancedFargateService(
      this,
      "Service",
      {
        vpc,
        cpu: config.ecs.cpu,
        memoryLimitMiB: config.ecs.memoryLimitMiB,
        desiredCount: config.ecs.minCapacity,
        healthCheckGracePeriod: cdk.Duration.seconds(
          config.ecs.healthCheckGracePeriodSeconds
        ),
        // Extra headroom during rolling deploys (temporarily up to 2x tasks,
        // never below 100%) and a fast rollback if the new task never goes
        // healthy, instead of the default up-to-3-hours-to-notice.
        minHealthyPercent: 100,
        maxHealthyPercent: 200,
        circuitBreaker: { rollback: true },
        assignPublicIp: true,
        taskSubnets: { subnetType: ec2.SubnetType.PUBLIC },
        securityGroups: [serviceSecurityGroup],
        publicLoadBalancer: true,
        loadBalancerName: `${config.appName}-alb`.slice(0, 32),
        certificate,
        domainName,
        domainZone,
        redirectHTTP: !!certificate,
        protocol: certificate
          ? elbv2.ApplicationProtocol.HTTPS
          : elbv2.ApplicationProtocol.HTTP,
        taskImageOptions: {
          image: ecs.ContainerImage.fromEcrRepository(
            repository,
            config.ecr.imageTag
          ),
          containerPort: config.ecs.containerPort,
          logDriver: ecs.LogDrivers.awsLogs({
            streamPrefix: config.appName,
            logGroup,
          }),
          environment: {
            RAILS_ENV: "production",
            RAILS_LOG_TO_STDOUT: "true",
            RAILS_SERVE_STATIC_FILES: "true",
            DATABASE_HOST: database.dbInstanceEndpointAddress,
            DATABASE_PORT: database.dbInstanceEndpointPort,
            DATABASE_NAME: config.database.databaseName,
            REDIS_URL: `redis://${redis.attrRedisEndpointAddress}:${redis.attrRedisEndpointPort}/1`,
          },
          secrets: {
            DATABASE_USERNAME: ecs.Secret.fromSecretsManager(
              database.secret!,
              "username"
            ),
            DATABASE_PASSWORD: ecs.Secret.fromSecretsManager(
              database.secret!,
              "password"
            ),
            RAILS_MASTER_KEY: ecs.Secret.fromSecretsManager(railsMasterKey),
          },
        },
      }
    );

    // The ALB's own security group already exists on the construct; fold in
    // the ingress rule defined above instead of letting the pattern create
    // its own wide-open one.
    fargateService.loadBalancer.addSecurityGroup(albSecurityGroup);

    fargateService.targetGroup.configureHealthCheck({
      path: config.ecs.healthCheckPath,
      healthyHttpCodes: "200",
    });

    // Fargate tasks pull the image, log to CloudWatch, and reach Secrets
    // Manager over the public internet (no NAT/VPC endpoints) since they
    // sit in public subnets with a public IP — allowAllOutbound above is
    // what makes that possible.
    railsMasterKey.grantRead(fargateService.taskDefinition.executionRole!);

    // ---------------------------------------------------------------------
    // Autoscaling: target-tracking on CPU. "cpu > 80%" in practice means
    // ECS keeps average utilization near the target by scaling out when
    // it's above and in when it's comfortably below — the standard way to
    // express that threshold, rather than a step alarm at exactly 80%.
    // ---------------------------------------------------------------------
    const scaling = fargateService.service.autoScaleTaskCount({
      minCapacity: config.ecs.minCapacity,
      maxCapacity: config.ecs.maxCapacity,
    });
    scaling.scaleOnCpuUtilization("CpuScaling", {
      targetUtilizationPercent: config.ecs.cpuTargetUtilizationPercent,
      scaleInCooldown: cdk.Duration.seconds(60),
      scaleOutCooldown: cdk.Duration.seconds(60),
    });

    // ---------------------------------------------------------------------
    // Outputs
    // ---------------------------------------------------------------------
    new cdk.CfnOutput(this, "LoadBalancerUrl", {
      value: `${certificate ? "https" : "http"}://${
        domainName ?? fargateService.loadBalancer.loadBalancerDnsName
      }`,
    });
    new cdk.CfnOutput(this, "RepositoryUri", { value: repository.repositoryUri });
    new cdk.CfnOutput(this, "DatabaseEndpoint", {
      value: database.dbInstanceEndpointAddress,
    });
    new cdk.CfnOutput(this, "DatabaseSecretArn", {
      value: database.secret!.secretArn,
    });
  }
}
