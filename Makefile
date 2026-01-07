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
	aws eks update-kubeconfig --alias grafana-eks --region $(AWS_REGION) --name $(CLUSTER_NAME) --profile $(AWS_PROFILE)
	
install-drivers:
	@echo "Associating OIDC provider with cluster"
	AWS_PROFILE=$(AWS_PROFILE) eksctl utils associate-iam-oidc-provider \
		--cluster=$(CLUSTER_NAME) \
		--region=$(AWS_REGION) \
		--approve || true
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
	@echo "Installing Cluster Autoscaler..."
	$(eval CLUSTER_AUTOSCALER_POLICY_ARN := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`ClusterAutoscalerPolicyArn`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	AWS_PROFILE=$(AWS_PROFILE) eksctl create iamserviceaccount \
		--cluster=$(CLUSTER_NAME) \
		--namespace=kube-system \
		--name=cluster-autoscaler \
		--role-name AmazonEKSClusterAutoscalerRole \
		--attach-policy-arn=$(CLUSTER_AUTOSCALER_POLICY_ARN) \
		--approve \
		--region=$(AWS_REGION)
	helm repo add autoscaler https://kubernetes.github.io/autoscaler
	helm repo update
	helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
		--namespace kube-system \
		--version=9.43.2 \
		--set autoDiscovery.clusterName=$(CLUSTER_NAME) \
		--set awsRegion=$(AWS_REGION) \
		--set serviceAccount.create=false \
		--set serviceAccount.name=cluster-autoscaler
	@echo "Installing Secrets Store CSI Driver..."
	helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
	helm repo update
	helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver \
		--namespace kube-system \
		--version=1.5.5 \
		--set syncSecret.enabled=true \
		--set enableSecretRotation=true \
		--set rotationPollInterval=15s
	kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
	kubectl patch daemonset csi-secrets-store-provider-aws -n kube-system --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/automountServiceAccountToken", "value":true}]'

install-istio:
	@echo "Installing Istio..."
	curl -L https://istio.io/downloadIstio | sh -
	$(eval ISTIO_VERSION := $(shell ls | grep istio- | head -1))
	export PATH=$$PWD/$(ISTIO_VERSION)/bin:$$PATH && istioctl install --set values.defaultRevision=default -y
	@echo "Enabling Istio injection for application namespaces..."
	kubectl label namespace grafana-stack istio-injection=enabled --overwrite
	kubectl label namespace postgres-stack istio-injection=enabled --overwrite
	@echo "Installing Istio addons..."
	kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/prometheus.yaml
	kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/grafana.yaml
	kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/jaeger.yaml
	kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/kiali.yaml
	@echo "Waiting for Istio components to be ready..."
	kubectl wait --for=condition=available --timeout=300s deployment/istiod -n istio-system

install-velero:
	@echo "Installing Velero..."
	$(eval VELERO_BUCKET := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`VeleroBackupBucket`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	$(eval VELERO_ROLE_ARN := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`VeleroRoleArn`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	@echo "Creating Pod Identity Association for Velero..."
	aws eks create-pod-identity-association \
		--cluster-name $(CLUSTER_NAME) \
		--namespace velero \
		--service-account velero \
		--role-arn $(VELERO_ROLE_ARN) \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE) || true
	helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
	helm repo update
	helm upgrade --install velero vmware-tanzu/velero \
		--namespace velero \
		--create-namespace \
		--version=7.2.1 \
		--set configuration.backupStorageLocation[0].name=default \
		--set configuration.backupStorageLocation[0].provider=aws \
		--set configuration.backupStorageLocation[0].bucket=$(VELERO_BUCKET) \
		--set configuration.backupStorageLocation[0].config.region=$(AWS_REGION) \
		--set configuration.volumeSnapshotLocation[0].name=default \
		--set configuration.volumeSnapshotLocation[0].provider=aws \
		--set configuration.volumeSnapshotLocation[0].config.region=$(AWS_REGION) \
		--set serviceAccount.server.create=true \
		--set serviceAccount.server.name=velero \
		--set kubectl.image.tag=1.34 \
		--set initContainers[0].name=velero-plugin-for-aws \
		--set initContainers[0].image=velero/velero-plugin-for-aws:v1.11.0 \
		--set initContainers[0].volumeMounts[0].mountPath=/target \
		--set initContainers[0].volumeMounts[0].name=plugins
	@echo "Waiting for Velero to be ready..."
	kubectl wait --for=condition=available --timeout=300s deployment/velero -n velero

install-fluent-bit:
	@echo "Installing AWS for Fluent Bit..."
	$(eval FLUENT_BIT_ROLE_ARN := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`FluentBitRoleArn`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	@echo "Creating Pod Identity Association for Fluent Bit..."
	aws eks create-pod-identity-association \
		--cluster-name $(CLUSTER_NAME) \
		--namespace amazon-cloudwatch \
		--service-account fluent-bit \
		--role-arn $(FLUENT_BIT_ROLE_ARN) \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE) || true
	helm repo add eks https://aws.github.io/eks-charts
	helm repo update
	helm upgrade --install aws-for-fluent-bit eks/aws-for-fluent-bit \
		--namespace amazon-cloudwatch \
		--create-namespace \
		--version=0.1.34 \
		--set cloudWatchLogs.enabled=true \
		--set cloudWatchLogs.region=$(AWS_REGION) \
		--set cloudWatchLogs.logGroupName=/aws/containerinsights/$(CLUSTER_NAME)/application \
		--set firehose.enabled=false \
		--set kinesis.enabled=false \
		--set elasticsearch.enabled=false \
		--set serviceAccount.create=true \
		--set resources.limits.memory=50Mi \
		--set resources.requests.memory=25Mi \
		--set serviceAccount.name=fluent-bit
		--set kinesis.enabled=false \
		--set elasticsearch.enabled=false \
		--set serviceAccount.create=true \
		--set resources.limits.memory=50Mi \
		--set resources.requests.memory=25Mi \
		--set serviceAccount.name=fluent-bit
	@echo "Waiting for Fluent Bit to be ready..."
	kubectl wait --for=condition=ready --timeout=300s pod -l app.kubernetes.io/name=aws-for-fluent-bit -n amazon-cloudwatch



deploy-k8s:
	@echo "Fetching CloudFormation outputs..."
	$(eval SM_ROLE_ARN := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`SecretsManagerRoleArn`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	$(eval EFS_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`EFSFileSystemId`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	@echo "Annotating CSI driver service account..."
	kubectl annotate serviceaccount -n kube-system csi-secrets-store-provider-aws eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
	@echo "Updating manifest with EFS ID: $(EFS_ID)"
	sed 's/fs-xxxxxxxxx/$(EFS_ID)/g' k8s-manifests/04-storage-class.yaml.template > k8s-manifests/04-storage-class-updated.yaml
	@echo "Deploying Kubernetes manifests..."
	kubectl apply -f k8s-manifests/
	@echo "Waiting for consolidated ingress to be ready..."
	@kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].hostname}' ingress/consolidated-alb -n grafana-stack --timeout=300s
	@echo "Getting Ingress value for ALB in ENV"
	$(eval ALB_DNS := $(shell kubectl get ingress consolidated-alb -n grafana-stack -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'))
	@echo "Setting ALB_DNS in ENV variable"
	@kubectl set env deployment/grafana -n grafana-stack GF_SERVER_ROOT_URL=https://$(ALB_DNS)/grafana/
	@echo "Getting Secret Manager Role Arn"
	kubectl annotate serviceaccount -n grafana-stack secrets-store-sa eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
	kubectl annotate serviceaccount -n postgres-stack secrets-store-sa eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
	kubectl wait --for=condition=available --timeout=300s deployment/grafana -n grafana-stack
#	kubectl annotate serviceaccount -n pgadmin-stack secrets-store-sa eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
update-k8s:
	@echo "Fetching CloudFormation outputs..."
	$(eval SM_ROLE_ARN := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`SecretsManagerRoleArn`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	$(eval EFS_ID := $(shell aws cloudformation describe-stacks --stack-name $(STACK_NAME) --query 'Stacks[0].Outputs[?OutputKey==`EFSFileSystemId`].OutputValue' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)))
	@echo "Updating manifest with EFS ID: $(EFS_ID)"
	sed 's/fs-xxxxxxxxx/$(EFS_ID)/g' k8s-manifests/04-storage-class.yaml.template > k8s-manifests/04-storage-class-updated.yaml
	@echo "Updating Kubernetes manifests..."
	kubectl apply -f k8s-manifests/
	@echo "Annotating service accounts..."
	kubectl annotate serviceaccount -n kube-system csi-secrets-store-provider-aws eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
	kubectl annotate serviceaccount -n grafana-stack secrets-store-sa eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite
	kubectl annotate serviceaccount -n postgres-stack secrets-store-sa eks.amazonaws.com/role-arn=$(SM_ROLE_ARN) --overwrite


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

delete-istio:
	@echo "Removing Istio injection labels..."
	kubectl label namespace grafana-stack istio-injection- || true
	kubectl label namespace postgres-stack istio-injection- || true
	@echo "Deleting Istio addons..."
	kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/kiali.yaml || true
	kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/jaeger.yaml || true
	kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/grafana.yaml || true
	kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/addons/prometheus.yaml || true
	@echo "Uninstalling Istio..."
	$(eval ISTIO_VERSION := $(shell ls | grep istio- | head -1))
	export PATH=$$PWD/$(ISTIO_VERSION)/bin:$$PATH && istioctl uninstall --purge -y || true
	kubectl delete namespace istio-system || true

delete-velero:
	@echo "Deleting Pod Identity Association for Velero..."
	aws eks delete-pod-identity-association \
		--cluster-name $(CLUSTER_NAME) \
		--association-id $(shell aws eks list-pod-identity-associations --cluster-name $(CLUSTER_NAME) --service-account velero --namespace velero --query 'associations[0].associationId' --output text --region $(AWS_REGION) --profile $(AWS_PROFILE)) \
		--region $(AWS_REGION) \
		--profile $(AWS_PROFILE) || true
	@echo "Uninstalling Velero..."
	helm uninstall velero -n velero || true
	kubectl delete namespace velero || true

delete-fluent-bit:
	@echo "Uninstalling Fluent Bit..."
	helm uninstall aws-for-fluent-bit -n amazon-cloudwatch || true
	kubectl delete namespace amazon-cloudwatch || true

delete-k8s:
	@echo "Deleting manifests..."
	kubectl delete -f k8s-manifests/ --ignore-not-found=true 2>/dev/null || true

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


update: update-eks install-drivers update-k8s
	@echo "Updatd EKS Cluster..."

# Full deployment workflow
deploy: deploy-eks install-drivers install-velero deploy-k8s
	@echo "EKS deployment complete!"
	@echo "Access Grafana at: https://grafana.hws-gruppe.de"
	@echo "Access pgAdmin at: https://pgadmin.hws-gruppe.de"
	@echo "Access Kiali at: kubectl port-forward svc/kiali 20001:20001 -n istio-system"
	@echo "Create backup with: velero backup create my-backup --include-namespaces grafana-stack,postgres-stack"

# Full cleanup workflow
clean: delete-k8s delete-fluent-bit delete-velero delete-istio delete-drivers delete-eks
	@echo "EKS cleanup complete!"