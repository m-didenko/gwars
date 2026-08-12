#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { GwarsStack } from "../lib/gwars-stack";
import { loadConfig } from "../lib/config";

const config = loadConfig();
const app = new cdk.App();

new GwarsStack(app, `${config.appName}-stack`, {
  config,
  // Account/region come from the CLI's own credentials (AWS_PROFILE, or
  // --profile on the cdk command) rather than being written down here —
  // that's what lets the same app deploy into any account.
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});
