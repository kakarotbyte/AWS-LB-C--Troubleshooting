data "aws_availability_zones" "available" {}

################################################################################
# VPC
################################################################################
module scenario_two_vpc {
    source = "terraform-aws-modules/vpc/aws"
    version = "5.5.2"
    name = var.cluster_name
    cidr = "10.0.0.0/16"
    azs = data.aws_availability_zones.available.names
    private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
    public_subnets =  ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
    enable_nat_gateway = true
    single_nat_gateway = true
    enable_dns_hostnames = true
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "type" = "public"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "type" = "private"
  }

  tags = {
    "test" = "Demo-VPC"
}
}
################################################################################
# EKS Cluster
################################################################################

module "eks-2" {
  source  = "terraform-aws-modules/eks/aws"

  cluster_name    = var.cluster_name
  cluster_version = "1.28"

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  vpc_id                   = module.scenario_two_vpc.vpc_id
  subnet_ids               = module.scenario_two_vpc.private_subnets
  control_plane_subnet_ids = module.scenario_two_vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    instance_types = ["m5.large"]
  }
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  eks_managed_node_groups = {
    red = {
      min_size     = 1
      max_size     = 1
      desired_size = 1

      instance_types = ["m5.large"]
    }
  }
  # aws-auth configmap
  #manage_aws_auth_configmap = false

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

################################################################################
# new policy doc
################################################################################
 resource "aws_iam_policy" "awslbc_custom_policy-2" {
   #name        = "awslbc_custom_policy"
   #description = "awslbc_custom_policy"

   # Terraform's "jsonencode" function converts a
   # Terraform expression result to valid JSON syntax.
   #policy = file("modules/one/policy.json")
   policy = file("modules/one/policy-fix.json")
 }

data "aws_iam_policy_document" "AWSLBC_policy_driver_assume_role_policy-2" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks-2.oidc_provider_arn, "/^(.*provider/)/", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    principals {
      identifiers = [module.eks-2.oidc_provider_arn]
      type        = "Federated"
    }
  }
  depends_on = [aws_iam_policy.awslbc_custom_policy-2]
}

resource "aws_iam_role" "aws_load_balancer_controller-2" {
  assume_role_policy   = data.aws_iam_policy_document.AWSLBC_policy_driver_assume_role_policy-2.json
}


resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller-2" {
  policy_arn = aws_iam_policy.awslbc_custom_policy-2.arn
  role       = aws_iam_role.aws_load_balancer_controller-2.name
}


################################################################################
# Aws Load balancer Controller Service Account
################################################################################
 resource "kubernetes_service_account" "service-account-2" {
   metadata {
     name      = "aws-load-balancer-controller"
     namespace = "kube-system"
     labels = {
       "app.kubernetes.io/name"      = "aws-load-balancer-controller"
       "app.kubernetes.io/component" = "controller"
     }
     annotations = {
       "eks.amazonaws.com/role-arn"               = aws_iam_role.aws_load_balancer_controller-2.arn
       "eks.amazonaws.com/sts-regional-endpoints" = "true"
     }
   }
   depends_on = [module.eks-2]
 }


################################################################################
# Install Load Balancer Controler With Helm
################################################################################

resource "helm_release" "lb-2" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.helm_chart_version
  namespace  = "kube-system"
  depends_on = [
    kubernetes_service_account.service-account-2,
    module.eks-2,
  ]

  set {
    name  = "region"
    value = "us-east-1"
  }


  set {
    name  = "vpcId"
    value = module.scenario_two_vpc.vpc_id
  }

  set {
    name  = "image.repository"
    value = "602401143452.dkr.ecr.us-east-1.amazonaws.com/amazon/aws-load-balancer-controller"
  }
  #set {
  #  name  = "image.tag"
  #  value = "v2.4.7"
  #}

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
}

################################################################################
# Adding sample APP
################################################################################
 resource "kubectl_manifest" "nginx_deploy-2" {
     yaml_body = <<YAML
 apiVersion: apps/v1
 kind: Deployment
 metadata:
   name: nginx-deployment
   labels:
     app: nginx
 spec:
   replicas: 3
   selector:
     matchLabels:
       app: nginx
   template:
     metadata:
       labels:
         app: nginx
     spec:
       containers:
       - name: nginx
         image: nginx:1.14.2
         ports:
         - containerPort: 80
 YAML
 depends_on = [ module.eks-2]
 }




# ################################################################################
# # Adding sample service with node port
# ################################################################################
 resource "kubectl_manifest" "service-2" {
     yaml_body = <<YAML
 apiVersion: v1
 kind: Service
 metadata:
   annotations:
   labels:
     app: nginx
   name: nginx
 spec:
   ports:
   - port: 80
     protocol: TCP
     targetPort: 80
   selector:
     app: nginx
   type: NodePort
 YAML
 depends_on = [helm_release.lb-2,kubectl_manifest.nginx_deploy-2, module.eks-2]
 }

# ################################################################################
# # Adding sample service without nodeport
# ################################################################################
 resource "kubectl_manifest" "service_clusterip-2" {
     yaml_body = <<YAML
 apiVersion: v1
 kind: Service
 metadata:
   annotations:
   labels:
     app: nginx
   name: nginx-clusterip
 spec:
   ports:
   - port: 80
     protocol: TCP
     targetPort: 80
   selector:
     app: nginx
   #type: ClusterIP
   type: NodePort
 YAML
 depends_on = [helm_release.lb-2, module.eks-2]
 }


# ################################################################################
# # Adding sample ingress
# ################################################################################
 resource "kubectl_manifest" "ingress-2" {
     yaml_body = <<YAML
 apiVersion: networking.k8s.io/v1
 kind: Ingress
 metadata:
   name: nginx
   annotations:
     alb.ingress.kubernetes.io/scheme: internet-facing
     alb.ingress.kubernetes.io/target-type: ip
     alb.ingress.kubernetes.io/group.name: awesome-team
     alb.ingress.kubernetes.io/subnets: "${module.scenario_two_vpc.public_subnets[1]},${module.scenario_two_vpc.public_subnets[0]}"

 spec:
   ingressClassName: alb
   rules:
     - http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: nginx
               port:
                 number: 80
 YAML
 depends_on=[module.eks-2]
 }

# ################################################################################
# # Adding sample ingress2
# ################################################################################
 resource "kubectl_manifest" "ingress-3" {
     yaml_body = <<YAML
 apiVersion: networking.k8s.io/v1
 kind: Ingress
 metadata:
   name: nginx-2
   annotations:
     alb.ingress.kubernetes.io/scheme: internet-facing
     alb.ingress.kubernetes.io/target-type: ip
     alb.ingress.kubernetes.io/group.name: awesome-team
     alb.ingress.kubernetes.io/subnets: "${module.scenario_two_vpc.private_subnets[1]},${module.scenario_two_vpc.private_subnets[0]}"

 spec:
   ingressClassName: alb
   rules:
     - http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: nginx
               port:
                 number: 80
 YAML
 depends_on = [ kubectl_manifest.ingress-2, module.eks-2]
 }
