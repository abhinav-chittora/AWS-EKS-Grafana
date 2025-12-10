# EKS Deployment with Grafana, PostgreSQL, and pgAdmin

Production-ready EKS cluster deployment with Grafana (Azure AD SSO), PostgreSQL database, and pgAdmin management interface using AWS CloudFormation and Kubernetes.

## Architecture

- **EKS Cluster**: Kubernetes 1.34 with Bottlerocket nodes
- **Networking**: VPC with public/private subnets across 2 AZs
- **Storage**: EFS for persistent data (Grafana & PostgreSQL)
- **Security**: AWS Secrets Manager with CSI driver, KMS encryption
- **Ingress**: AWS ALB with SSL/TLS termination
- **Autoscaling**: Cluster Autoscaler for node scaling

## Prerequisites

- AWS CLI configured with appropriate credentials
- kubectl installed
- eksctl installed
- helm installed
- AWS account with permissions for EKS, VPC, IAM, Secrets Manager

## Quick Start

### 1. Deploy EKS Infrastructure

```bash
make deploy-eks
```

This creates:

- VPC with public/private subnets
- EKS cluster with managed node group
- IAM roles and policies
- EFS file system
- Secrets in AWS Secrets Manager

### 2. Install Required Drivers

```bash
make install-drivers
```

Installs:

- AWS Load Balancer Controller
- Cluster Autoscaler
- Secrets Store CSI Driver

### 3. Deploy Applications

```bash
make deploy-k8s
```

Deploys:

- PostgreSQL database
- Grafana with Azure AD SSO
- pgAdmin interface

### Full Deployment (All Steps)

```bash
make deploy
```

## Configuration

### Makefile Variables

Override defaults by setting environment variables:

```bash
STACK_NAME=my-stack AWS_REGION=us-east-1 make deploy-eks
```

| Variable | Default | Description |
|----------|---------|-------------|
| STACK_NAME | grafana-eks | CloudFormation stack name |
| AWS_REGION | eu-central-1 | AWS region |
| AWS_PROFILE | ecs-test | AWS CLI profile |
| PARAMETERS_FILE | parameters.json | CloudFormation parameters file |

### CloudFormation Parameters

Required parameters in `parameters.json`:

- **CertificateArn**: ACM certificate ARN for HTTPS
- **GrafanaDomainName**: Domain for Grafana access
- **AzureClientId**: Azure AD application client ID
- **AzureClientSecret**: Azure AD application secret
- **AzureTenantId**: Azure AD tenant ID
- **GrafanaAdminPassword**: Grafana admin password
- **PostgresAdminPassword**: PostgreSQL admin password
- **PgAdminEmail**: pgAdmin login email
- **PgAdminPassword**: pgAdmin password
- **TagProject**: Project tag value
- **TagOwner**: Owner tag value

## Components

### EKS Cluster

- **Version**: 1.34
- **Node Type**: t3.medium (Bottlerocket)
- **Scaling**: 1-3 nodes (auto-scaling enabled)
- **Addons**: EBS CSI, EFS CSI, VPC CNI, CoreDNS, Pod Identity Agent

### Grafana

- **Image**: grafana/grafana:latest
- **Authentication**: Azure AD SSO + local admin
- **Storage**: EFS-backed persistent volume (5Gi)
- **Access**: HTTPS via ALB
- **Plugins**: grafana-piechart-panel

### PostgreSQL

- **Image**: postgres:17.6
- **Database**: amazon_connect
- **User**: admin
- **Storage**: EFS-backed persistent volume (5Gi)
- **Port**: 5432 (internal only)

### pgAdmin

- **Image**: dpage/pgadmin4:latest
- **Access**: HTTPS via ALB (port 8080)

## Security

### Secrets Management

All secrets stored in AWS Secrets Manager:

- Grafana admin password
- Azure AD credentials
- PostgreSQL password
- pgAdmin credentials

Secrets mounted via CSI driver (no environment variables).

### Encryption

- **EKS secrets**: Encrypted with KMS
- **EFS**: Encrypted at rest
- **Secrets Manager**: KMS encrypted
- **Traffic**: TLS/SSL via ALB

### IAM

- IRSA (IAM Roles for Service Accounts) for pod-level permissions
- Least privilege access policies
- Pod Identity for EKS addons

## Management Commands

### Status & Information

```bash
make status          # Check stack status
make outputs         # View stack outputs
```

### Updates

```bash
make update-eks      # Update EKS stack
```

### Cleanup

```bash
make delete-k8s      # Delete Kubernetes resources
make delete-drivers  # Remove drivers and controllers
make delete-eks      # Delete CloudFormation stack
make clean           # Full cleanup (all above)
```

## Accessing Applications

After deployment:

```bash
# Get Grafana URL
kubectl get ingress grafana -n grafana-stack

# Get pgAdmin URL
kubectl get ingress pgadmin -n pgadmin-stack
```

### Grafana Login

- **URL**: https://[your-domain]
- **Username**: admin
- **Password**: From AWS Secrets Manager (GrafanaAdminPasswordSecret)
- **SSO**: Azure AD authentication enabled

### pgAdmin Login

- **URL**: https://[your-domain]:8080
- **Email**: From AWS Secrets Manager (PgAdminEmailSecret)
- **Password**: From AWS Secrets Manager (PgAdminPasswordSecret)

## Troubleshooting

### Check pod status

```bash
kubectl get pods -n grafana-stack
kubectl get pods -n postgres-stack
kubectl get pods -n pgadmin-stack
```

### View logs

```bash
kubectl logs -n grafana-stack deployment/grafana
kubectl logs -n postgres-stack deployment/postgres
kubectl logs -n pgadmin-stack deployment/pgadmin
```

### Verify secrets mounting

```bash
kubectl exec -n grafana-stack deployment/grafana -- ls -la /mnt/secrets-store
```

### Check ALB status

```bash
kubectl describe ingress grafana -n grafana-stack
```

## Cost Optimization

- **Node Type**: t3.medium (adjust based on workload)
- **Scaling**: Min 1, Max 3 nodes (tune as needed)
- **EFS**: Provisioned only when needed
- **NAT Gateway**: Single NAT in one AZ (add more for HA)

## Network Architecture

```mermaid
graph LR
    Internet[Internet] --> IGW[Internet Gateway]
    IGW --> PublicSubnets[Public Subnets<br/>2 AZs]
    PublicSubnets --> NAT[NAT Gateway]
    PublicSubnets --> ALB[Application Load Balancer]
    NAT --> PrivateSubnets[Private Subnets<br/>2 AZs]
    ALB --> PrivateSubnets
    PrivateSubnets --> EKS[EKS Nodes]
    EKS --> Grafana[Grafana POD]
    EKS --> PostgreSQL[PostgreSQL POD]
    EKS --> pgAdmin[pgAdmin POD]
```

## File Structure

```plaintext
.
├── .gitignore                          # Git ignore rules
├── Makefile                            # Deployment automation
├── grafana-eks.yaml                    # CloudFormation template
└── k8s-secrets-manager-csi.yaml        # Kubernetes manifests
└── parameters.json                     # CloudFormation parameters
```

## License

Internal use only.
