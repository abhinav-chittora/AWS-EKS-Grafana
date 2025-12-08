# EKS Deployment Makefile
STACK_NAME ?= grafana-eks
AWS_REGION ?= eu-central-1
AWS_PROFILE ?= ecs-test
PARAMETERS_FILE ?= parameters.json
CLUSTER_NAME = $(STACK_NAME)-cluster

.PHONY: help deploy-eks install-drivers deploy-k8s delete-drivers delete-k8s delete-eks status outputs validate update

help:
	@echo "Available targets:"
	@echo "  deploy-eks     - Deploy EKS CloudFormation stack"
	@echo "  install-drivers - Install required CSI drivers and controllers"
	@echo "  deploy-k8s     - Deploy Kubernetes manifests"
	@echo "  update-eks 	- Update EKS CloudFormation stack"
	@echo "  delete-drivers - Delete CSI drivers and service accounts"
	@echo "  delete-k8s     - Delete Kubernetes resources"
	@echo "  delete-eks     - Delete EKS CloudFormation stack"
	@echo "  status         - Check stack status"
	@echo "  outputs        - Get stack outputs"
	@echo "  validate       - Validate CloudFormation template"
	@echo "  update         - Update existing stack"

deploy-eks:
	@echo "Deploying EKS CloudFormation stack..."
	aws cloudformation deploy \
		--template-file grafana-eks.yaml \
		--stack-name $(STACK_NAME) \
		--parameter-overrides file://$(PARAMETERS_FILE) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE)
	@echo "Updating kubeconfig..."
	aws eks update-kubeconfig --alias grafana-eks --region $(AWS_REGION) --name $(CLUSTER_NAME) --profile $(AWS_PROFILE)

update-eks:
	@echo "Updating EKS CloudFormation stack..."
	aws cloudformation deploy \
		--template-file grafana-eks.yaml \
		--stack-name $(STACK_NAME) \
		--parameter-overrides file://$(PARAMETERS_FILE) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE)
	@echo "Updating kubeconfig..."
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(CLUSTER_NAME) --profile $(AWS_PROFILE)
	@echo "Restarting CNI pods to apply new configuration..."
	kubectl delete pods -n kube-system -l k8s-app=aws-node
	kubectl wait --for=condition=ready --timeout=300s pod -l k8s-app=aws-node -n kube-system
	
install-drivers:
	@echo "Associating OIDC provider with cluster"
	AWS_PROFILE=$(AWS_PROFILE) eksctl utils associate-iam-oidc-provider \
		--cluster=$(CLUSTER_NAME) \
		--region=$(AWS_REGION) \
		--approve || true
	@echo "Get OIDC Provider..."
	$(eval OIDC_PROVIDER := $(shell aws eks describe-cluster --name $(CLUSTER_NAME) --query 'cluster.identity.oidc.issuer' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	@echo "Installing AWS Load Balancer Controller..."
	$(eval LB_POLICY_ARN := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerControllerPolicyArn`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	AWS_PROFILE=$(AWS_PROFILE) eksctl create iamserviceaccount \
		--cluster=$(CLUSTER_NAME) \
		--namespace=kube-system \
		--name=aws-load-balancer-controller \
		--role-name AmazonEKSLoadBalancerControllerRole \
		--attach-policy-arn=$(LB_POLICY_ARN) \
		--approve \
		--region=$(AWS_REGION)
	helm repo add eks https://aws.github.io/eks-charts
	helm repo update
	helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
		-n kube-system \
		--version=1.16.0 \
		--set clusterName=$(CLUSTER_NAME) \
		--set serviceAccount.create=false \
		--set serviceAccount.name=aws-load-balancer-controller
	@echo "Waiting for AWS Load Balancer Controller to be ready..."
	kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system
	kubectl wait --for=condition=ready --timeout=300s pod -l app.kubernetes.io/name=aws-load-balancer-controller -n kube-system
	@echo "Waiting 30 seconds for webhook to fully initialize..."
	sleep 30
	@echo "Installing Cluster Autoscaler..."
	$(eval CA_ROLE_ARN := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`ClusterAutoscalerRoleArn`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	@echo "Creating Pod Identity Association for Cluster Autoscaler..."
	aws eks create-pod-identity-association \
		--cluster-name $(CLUSTER_NAME) \
		--namespace kube-system \
		--service-account cluster-autoscaler-aws-cluster-autoscaler \
		--role-arn $(CA_ROLE_ARN) \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE) || true
	helm repo add autoscaler https://kubernetes.github.io/autoscaler
	helm repo update
	helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
		--namespace kube-system \
		--version=9.52.1 \
		--set autoDiscovery.clusterName=$(CLUSTER_NAME) \
		--set awsRegion=$(AWS_REGION) \
		--set serviceAccount.create=true \
		--set serviceAccount.name=cluster-autoscaler-aws-cluster-autoscaler \
		--set extraArgs.skip-nodes-with-local-storage=false \
		--set extraArgs.skip-nodes-with-system-pods=false
	@echo "Installing Secrets Store CSI Driver..."
	helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
	helm repo update
	helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
		--namespace kube-system \
		--version=1.5.4
		--set syncSecret.enabled=true \
		--set enableSecretRotation=true \
		--set rotationPollInterval=15s 
	kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
	kubectl patch daemonset csi-secrets-store-provider-aws -n kube-system --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/automountServiceAccountToken", "value":true}]'



deploy-k8s:
	@echo "Fetching CloudFormation outputs..."
	$(eval SM_ROLE_ARN := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`SecretsManagerRoleArn`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	$(eval EFS_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`EFSFileSystemId`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
# 	@echo "Fetching secrets from Secrets Manager..."
# 	$(eval GRAFANA_PASS := $(shell aws secretsmanager get-secret-value --secret-id GrafanaAdminPasswordSecret --query SecretString --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
# 	$(eval AZURE_CLIENT_ID := $(shell aws secretsmanager get-secret-value --secret-id AzureClientIdSecret --query SecretString --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
# 	$(eval AZURE_CLIENT_SECRET := $(shell aws secretsmanager get-secret-value --secret-id AzureClientSecretSecret --query SecretString --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
# 	$(eval AZURE_TENANT_ID := $(shell aws secretsmanager get-secret-value --secret-id AzureTenantIdSecret --query SecretString --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
# 	$(eval POSTGRES_PASS := $(shell aws secretsmanager get-secret-value --secret-id PostgresAdminPasswordSecret --query SecretString --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
# 	$(eval PGADMIN_EMAIL := $(shell aws secretsmanager get-secret-value --secret-id PgAdminEmailSecret --query SecretString --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
# 	$(eval PGADMIN_PASS := $(shell aws secretsmanager get-secret-value --secret-id PgAdminPasswordSecret --query SecretString --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	@echo "Annotating CSI driver service account..."
	kubectl annotate serviceaccount -n kube-system csi-secrets-store-provider-aws eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
	@echo "Updating manifest with EFS ID: $(EFS_ID)"
	sed 's/fs-xxxxxxxxx/$(EFS_ID)/g' k8s-secrets-manager-csi.yaml > k8s-secrets-manager-updated.yaml
	@echo "Deploying Kubernetes manifests..."
	kubectl apply -f k8s-secrets-manager-updated.yaml
# 	@echo "Creating Kubernetes secrets..."
# 	kubectl create secret generic grafana-secret --from-literal=admin-password=$(GRAFANA_PASS) --from-literal=azure-client-id=$(AZURE_CLIENT_ID) --from-literal=azure-client-secret=$(AZURE_CLIENT_SECRET) --from-literal=azure-tenant-id=$(AZURE_TENANT_ID) -n grafana-stack --dry-run=client -o yaml | kubectl apply -f -
# 	kubectl create secret generic postgres-secret --from-literal=password=$(POSTGRES_PASS) -n postgres-stack --dry-run=client -o yaml | kubectl apply -f -
# 	kubectl create secret generic pgadmin-secret --from-literal=email=$(PGADMIN_EMAIL) --from-literal=password=$(PGADMIN_PASS) -n pgadmin-stack --dry-run=client -o yaml | kubectl apply -f -
	@echo "Waiting for Grafana ingress to be ready..."
	@kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' ingress/grafana -n grafana-stack --timeout=300s
	@echo "Getting Ingress value for ALB in ENV"
	$(eval ALB_DNS := $(shell kubectl get ingress grafana -n grafana-stack -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'))
	@echo "Setting ALB_DNS in ENV variable"
	@kubectl set env deployment/grafana -n grafana-stack GF_SERVER_ROOT_URL=https://$(ALB_DNS)
	@echo "Getting Secret Manager Role Arn"
	kubectl annotate serviceaccount -n grafana-stack secrets-store-sa eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
	kubectl annotate serviceaccount -n postgres-stack secrets-store-sa eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
	kubectl annotate serviceaccount -n pgadmin-stack secrets-store-sa eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
	kubectl wait --for=condition=available --timeout=300s deployment/grafana -n grafana-stack


delete-drivers:
	@echo "Deleting Pod Identity Association for Cluster Autoscaler..."
	aws eks delete-pod-identity-association \
		--cluster-name $(CLUSTER_NAME) \
		--association-id $(shell aws eks list-pod-identity-associations --cluster-name $(CLUSTER_NAME) --service-account cluster-autoscaler-aws-cluster-autoscaler --namespace kube-system --query 'associations[0].associationId' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)) \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE) || true
	@echo "Deleting Helm releases..."
	helm uninstall cluster-autoscaler -n kube-system || true
	helm uninstall aws-load-balancer-controller -n kube-system || true
	helm uninstall csi-secrets-store -n kube-system || true
	@echo "Deleting AWS provider for secrets store..."
	kubectl delete -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml || true
	@echo "Deleting IRSA for Secrets Manager..."
	AWS_PROFILE=$(AWS_PROFILE) eksctl delete iamserviceaccount \
		--name secrets-store-sa \
		--namespace grafana-stack \
		--cluster $(CLUSTER_NAME) \
		--region $(AWS_REGION) || true
	AWS_PROFILE=$(AWS_PROFILE) eksctl delete iamserviceaccount \
		--name csi-secrets-store-provider-aws \
		--namespace kube-system \
		--cluster $(CLUSTER_NAME) \
		--region $(AWS_REGION) || true


	AWS_PROFILE=$(AWS_PROFILE) eksctl delete iamserviceaccount \
		--name aws-load-balancer-controller \
		--namespace kube-system \
		--cluster $(CLUSTER_NAME) \
		--region $(AWS_REGION) || true

delete-k8s:
	@echo "Deleting Kubernetes resources..."
	@echo "Deleting ingresses..."
	kubectl delete ingress --all -n grafana-stack --ignore-not-found=true || true
	kubectl delete ingress --all -n postgres-stack --ignore-not-found=true || true
	kubectl delete ingress --all -n pgadmin-stack --ignore-not-found=true || true
	@echo "Force deleting pods..."
	kubectl delete pods --all --grace-period=0 --force -n grafana-stack --ignore-not-found=true 2>/dev/null || true
	kubectl delete pods --all --grace-period=0 --force -n postgres-stack --ignore-not-found=true 2>/dev/null || true
	kubectl delete pods --all --grace-period=0 --force -n pgadmin-stack --ignore-not-found=true 2>/dev/null || true
	@echo "Removing namespace finalizers..."
	kubectl patch ns grafana-stack -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	kubectl patch ns postgres-stack -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	kubectl patch ns pgadmin-stack -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	@echo "Deleting manifests..."
	kubectl delete -f k8s-secrets-manager-updated.yaml --ignore-not-found=true 2>/dev/null || true

delete-eks:
	@echo "Deleting EKS CloudFormation stack..."
	aws cloudformation delete-stack \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE)
	@echo "Waiting for stack deletion..."
	aws cloudformation wait stack-delete-complete \
		--stack-name $(STACK_NAME) \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE)

status:
	@aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].StackStatus' \
		--output text \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE)

outputs:
	@aws cloudformation describe-stacks \
		--stack-name $(STACK_NAME) \
		--query 'Stacks[0].Outputs' \
		--output table \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE)

validate:
	@aws cloudformation validate-template \
		--template-body file://grafana-eks.yaml \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE)


update:
	# 	@echo "Deleting existing nodegroup..."
	# 	aws eks delete-nodegroup --cluster-name $(CLUSTER_NAME) --nodegroup-name $(STACK_NAME)-nodegroup --region $(AWS_REGION) --profile $(AWS_PROFILE) || true
	# 	@echo "Waiting for nodegroup deletion..."
	# 	aws eks wait nodegroup-deleted --cluster-name $(CLUSTER_NAME) --nodegroup-name $(STACK_NAME)-nodegroup --region $(AWS_REGION) --profile $(AWS_PROFILE) || true
	@echo "Updating EKS CloudFormation stack..."
	aws cloudformation deploy \
		--template-file grafana-eks.yaml \
		--stack-name $(STACK_NAME) \
		--parameter-overrides file://$(PARAMETERS_FILE) \
		--capabilities CAPABILITY_NAMED_IAM \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE)

# Full deployment workflow
deploy: deploy-eks install-drivers deploy-k8s
	@echo "EKS deployment complete!"
	@echo "Access Grafana at: https://grafana.hws-gruppe.de"
	@echo "Access pgAdmin at: https://pgadmin.hws-gruppe.de"

# Full cleanup workflow
clean: delete-k8s delete-drivers delete-eks
	@echo "EKS cleanup complete!"