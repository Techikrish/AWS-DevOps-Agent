# aws devops agent lab

**A testbed for AWS DevOps Agent — featuring four chaos scenarios, a reusable Terraform module, and real investigation output.**

> Part of the [Production Infrastructure Series](https://medium.com/@krishnafattepurkar) on Medium.

[![Terraform](https://img.shields.io/badge/Terraform-≥1.9-7B42BC?logo=terraform)](https://terraform.io)
[![AWS](https://img.shields.io/badge/AWS-DevOps_Agent_GA-FF9900?logo=amazonaws)](https://aws.amazon.com/devops-agent/)
[![EKS](https://img.shields.io/badge/Kubernetes-EKS_1.32-326CE5?logo=kubernetes)](https://aws.amazon.com/eks/)

---

## What This Is

AWS DevOps Agent tested against real-world failure patterns. This repo is a **deliberately broken EKS environment** designed 

It contains:

- **Terraform module** — provisions Agent Space IAM roles, CloudWatch alarms, SNS routing, and Lambda function as code (no console clicking)
- **Four chaos scenarios** — escalating from a single OOMKill to a multi-service cascade failure
- **Investigation runbook** — uploaded as a Custom Skill to the Agent Space
- **GitHub Actions workflow** — simulates a deployment regression the agent can correlate

Read the full walkthrough: [Medium Article](https://medium.com/@krishnafattepurkar/aws-devops-agent-meets-chaos-how-i-wired-an-autonomous-sre-to-a-deliberately-broken-eks-cluster-1cc227c5ab06?sharedUserId=krishnafattepurkar)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    AWS DevOps Agent Space                    │
│                                                              │
│  ┌─────────────┐    ┌──────────────┐    ┌────────────────┐  │
│  │  Topology   │    │  Triage      │    │  RCA Agent     │  │
│  │  Map (auto) │───▶│  Agent       │───▶│                │  │
│  └─────────────┘    └──────────────┘    └────────────────┘  │
│         │                                        │           │
│         ▼                                        ▼           │
│  ┌─────────────┐                      ┌────────────────┐    │
│  │ CloudWatch  │                      │  Mitigation    │    │
│  │ Datadog/etc │                      │  Plan + Slack  │    │
│  └─────────────┘                      └────────────────┘    │
└──────────────────────────────────────────────────────────────┘
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│                   chaos-lab Namespace (EKS)                  │
│                                                              │
│  stress-app ──────────────────────────────────────────────  │
│  (Scenario 1: OOMKill, Scenario 4: Cascade source 1)        │
│                                                              │
│  api-gateway-app ─────────────────────────────────────────  │
│  (Scenario 2: Bad deploy, Scenario 4: Cascade target)       │
│                                                              │
│  slow-downstream (Lambda) ────────────────────────────────  │
│  (Scenario 3: Timeout, Scenario 4: Cascade source 2)        │
└──────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

> **Note:** Scenarios 1 (OOMKill) and 2 (Deployment Regression) require a live EKS cluster.
> The Terraform module in this repo provisions the **monitoring layer** (IAM, CloudWatch, SNS) — not the cluster itself.
> Follow the steps below to create one before running those scenarios.

### Required Tools

Make sure the following tools are installed and configured before you begin:

| Tool | Version | Check |
|---|---|---|
| AWS CLI | ≥ 2.x | `aws --version` |
| eksctl | ≥ 0.200.0 | `eksctl version` |
| kubectl | ≥ 1.32 | `kubectl version --client` |
| Helm | ≥ 3.x | `helm version` |
| Terraform | ≥ 1.9 (latest: 1.15.8) | `terraform version` |

Install `eksctl` if you don't have it:

```bash
# Linux / macOS (via curl)
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz"
tar -xzf eksctl_$(uname -s)_amd64.tar.gz
sudo mv eksctl /usr/local/bin

# macOS via Homebrew
brew tap weaveworks/tap && brew install weaveworks/tap/eksctl

# Verify
eksctl version
```

---

### Create the EKS Cluster

> **Skip this step if you already have an EKS cluster (1.32+) you want to point the agent at.**
> Just update `eks_cluster_name` in `terraform.tfvars` to match your existing cluster name.

Create a dedicated cluster for this lab using `eksctl`. This provisions a managed node group across two availability zones — enough to test the AZ-spread findings the agent surfaces:

```bash
eksctl create cluster \
  --name devops-agent-lab \
  --region us-east-1 \
  --version 1.32 \
  --nodegroup-name lab-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 4 \
  --managed \
  --with-oidc \
  --asg-access \
  --full-ecr-access \
  --alb-ingress-access \
  --zones us-east-1a,us-east-1b
```

This takes approximately **15–20 minutes**. The command creates:
- A managed EKS control plane (v1.32)
- A managed node group with 2× `t3.medium` nodes across two AZs
- An OIDC provider (required for IAM Roles for Service Accounts)
- Auto Scaling Group access (needed for Scenario 4 HPA)

Once done, verify the cluster and configure `kubectl`:

```bash
# Update your local kubeconfig
aws eks update-kubeconfig \
  --region us-east-1 \
  --name devops-agent-lab

# Verify nodes are Ready
kubectl get nodes
```

Expected output:
```
NAME                          STATUS   ROLES    AGE   VERSION
ip-192-168-x-x.ec2.internal   Ready    <none>   2m    v1.32.x
ip-192-168-x-x.ec2.internal   Ready    <none>   2m    v1.32.x
```

---

### Enable Container Insights

Container Insights is **required** for the CloudWatch memory alarms in Scenario 1 to fire. Enable it with a single `eksctl` command:

```bash
eksctl utils enable-addon \
  --name amazon-cloudwatch-observability \
  --cluster devops-agent-lab \
  --region us-east-1 \
  --approve
```

Verify the agent pods are running:

```bash
kubectl get pods -n amazon-cloudwatch
# Expected: cloudwatch-agent-* pods in Running state
```

> **Why this matters:** The `node_memory_utilization` metric used by the OOMKill CloudWatch alarm
> is published by the CloudWatch agent running inside the cluster via Container Insights.
> Without it, the alarm will never receive data and the agent investigation won't trigger.

---

### Create the chaos-lab Namespace

All lab workloads run in a dedicated namespace. Create it before applying any manifests:

```bash
kubectl create namespace chaos-lab
```

---

### Other Prerequisites

- **AWS DevOps Agent enabled** in your account — request access via the [AWS Console](https://console.aws.amazon.com/devops-agent) (GA in `us-east-1`, expanding to other regions)
- **GitHub repository** — required for Scenario 2 (deployment regression correlation). Fork this repo or use your own
- **Slack webhook** *(optional)* — for incident notification routing via SNS

---

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/Techikrish/AWS-DevOps-Agent.git
cd AWS-DevOps-Agent/terraform

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your cluster name and GitHub repo
```

Set secrets as environment variables — never hardcode them:

```bash
export TF_VAR_github_token="ghp_xxxxxxxxxxxxxxxxxxxx"
export TF_VAR_slack_webhook_url="https://hooks.slack.com/services/xxx"
```

### 2. Apply Terraform

```bash
terraform init
terraform plan
terraform apply
```

The output will print the execution role ARN and next steps:

```
next_steps = <<EOT
============================================================
NEXT STEPS — AWS DevOps Agent Lab Setup
============================================================
1. Go to AWS Console → DevOps Agent → Create Agent Space
2. Paste the execution role ARN: arn:aws:iam::123456789:role/...
3. Connect CloudWatch using SNS topic: arn:aws:sns:...
4. Connect GitHub using token from SSM: /devops-agent-lab/dev/github-token
5. Enable topology scan on cluster: your-cluster-name
...
```

### 3. Deploy the lab workloads

```bash
kubectl apply -f eks/app/deployment.yaml
kubectl apply -f eks/app/service.yaml
```

### 4. Upload the runbook as a Custom Skill

In the Agent Space web app:
- Navigate to **Skills → Custom Skills → Create**
- Paste the contents of `runbooks/investigation-hints.md`
- Set skill type to: `Incident RCA, Incident Triage`

---

## Running the Chaos Scenarios

### Scenario 1 — OOMKill

```bash
kubectl apply -f eks/chaos/oom-break.yaml

# Watch the carnage
kubectl get pods -n chaos-lab -w

# What you'll see:
# stress-app-xxx   0/1   OOMKilled   3   45s
# stress-app-xxx   0/1   Pending     3   46s
# stress-app-xxx   0/1   Running     4   48s  ← restart loop
```

**Wait:** Agent should start investigating within 60s of the CloudWatch alarm.

**Expected agent output:**
- Root cause: memory limit (64Mi) insufficient for process (256MB)
- Recommendation: increase `resources.limits.memory` to ≥ 512Mi
- Additional flags: missing PDB, single-AZ placement

---

### Scenario 2 — Deployment Regression

```bash
# Push to the chaos branch to trigger the bad GitHub Actions deployment
git checkout -b chaos-scenario-2
git push origin chaos-scenario-2

# Or trigger manually in GitHub Actions → bad-deploy.yml → Run workflow
```

**What happens:** The workflow deploys `values-broken.yaml` with a nonexistent
image tag. Pods go to ImagePullBackOff. Agent correlates the deployment timestamp
with the error spike.

**Expected agent output:**
- Root cause: `image.tag: 1.99-nonexistent` does not exist in registry
- Deployment correlation: GitHub Actions run #X at HH:MM:SS matches incident start
- Recommendation: rollback to previous Helm revision

---

### Scenario 3 — Lambda Timeout

```bash
# Get the Lambda URL from Terraform output
LAMBDA_URL=$(terraform output -raw lambda_function_url -chdir=terraform)

# Trigger it repeatedly — each call will timeout after 3s
for i in {1..10}; do
  curl -s "$LAMBDA_URL" &
done
wait
echo "All 10 calls timed out (expected)"
```

**Expected agent output:**
- Root cause: `ARTIFICIAL_DELAY_MS=4500` exceeds Lambda timeout of 3000ms
- X-Ray trace correlation: latency consistently at 3s cutoff
- Recommendation: increase timeout to ≥10s OR investigate slow operation

---

### Scenario 4 — Cascade Failure

First, get the Lambda URL and update the ConfigMap:

```bash
LAMBDA_URL=$(terraform output -raw lambda_function_url -chdir=terraform)
sed -i "s|REPLACE_WITH_LAMBDA_FUNCTION_URL|$LAMBDA_URL|g" eks/chaos/cascade-break.yaml
```

Then trigger both upstream failures simultaneously:

```bash
# Apply Scenario 1 (OOMKill) first
kubectl apply -f eks/chaos/oom-break.yaml

# Wait 30 seconds, then apply cascade
sleep 30
kubectl apply -f eks/chaos/cascade-break.yaml

# Trigger Lambda timeouts concurrently
for i in {1..20}; do curl -s "$LAMBDA_URL" & done
```

**This is the real test.** The agent must:
1. Identify two simultaneous root causes (OOMKill + Lambda timeout)
2. Correlate them to a single user-visible failure (api-gateway)
3. Recognize that HPA scaling is a symptom, not a cause
4. Provide separate mitigation steps for each root cause

---

## Resetting the Environment

```bash
# Remove all chaos manifests
kubectl delete -f eks/chaos/
kubectl delete -f eks/app/

# Reset to clean state
kubectl delete namespace chaos-lab

# Reapply base workloads (good config)
kubectl apply -f eks/app/
```

---

## Cleanup

```bash
cd terraform
terraform destroy
```

---

## What the Agent Flagged (Beyond the Obvious)

After running all four scenarios, the agent's **proactive recommendations** surfaced structural gaps that no alarm was monitoring:

1. `stress-app` has no PodDisruptionBudget — rolling updates can cause full outages
2. All `chaos-lab` pods landed on a single AZ — missing `topologySpreadConstraints`
3. No multi-AZ deployment for any workload in the namespace
4. Lambda function has no reserved concurrency — can be throttled by other functions
5. CloudWatch log retention is 14 days — insufficient for trend analysis the agent recommends

These weren't in any runbook. The agent found them by analyzing patterns across the incident history.

---

## Project Structure

```
aws-devops-agent
├── terraform/
│   ├── main.tf                    # Agent Space IAM, CloudWatch alarms, SNS
│   ├── lambda.tf                  # slow-downstream Lambda function
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── eks/
│   ├── app/
│   │   ├── deployment.yaml        # stress-app (memory misconfigured)
│   │   └── service.yaml           # api-gateway-app (cascade target)
│   ├── chaos/
│   │   ├── oom-break.yaml         # Scenario 1: OOMKill trigger
│   │   └── cascade-break.yaml    # Scenario 4: Multi-service cascade
│   └── helm/
│       └── values-broken.yaml    # Scenario 2: Deployment regression
├── lambda/
│   └── timeout-scenario/
│       └── handler.py             # Scenario 3: Artificial latency
├── github-actions/
│   └── bad-deploy.yml             # Scenario 2: CI/CD deployment trigger
├── runbooks/
│   └── investigation-hints.md    # Custom Skill for Agent Space
└── README.md
```

---



---

*Part of the Production Infrastructure Series — a collection of battle-tested patterns for engineers running production workloads on AWS.*
