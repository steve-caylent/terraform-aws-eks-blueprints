################################################################################
# EKS Providers
################################################################################
terraform {
  required_version = ">= 1.0.0"

  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 10
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
  load_config_file       = false
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "kubernetes" {
  host                   = module.eks_blueprints.eks_cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.eks_cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.eks_cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}


################################################################################
# EKS Module
################################################################################
data "aws_eks_cluster_auth" "this" {
  name = module.eks_blueprints.eks_cluster_id
}


  
#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------

module "eks_blueprints" {
  source = "git::https://github.com/ForresterTM/tf-eks.git"

  
  create_eks      = true
  cluster_name    = local.name
  cluster_version = "1.23"
  create_ssm_parameters = true
  ssm_path        = "/forrester/infra/eks/${var.env}/${var.region}/cluster${var.param_post_fix}/"

  # if running with vpc module replace with module.primary_vpc.vpc_id 
  vpc_id             = local.eks_vpc # dev
  # if running with vpc module replace with module.primary_vpc.private_subnets 
  private_subnet_ids = local.eks_subnets # dev

  cluster_endpoint_private_access = true

  map_roles = [
    {
      rolearn     = local.eks_admin_auth
      username      = "admin"
      groups       = ["system:masters"]
    },
    {
      rolearn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/codebuild-service-role"
      username      = "codebuild"
      groups       = ["system:masters"]
    },
    {
      rolearn     = local.eks_devops_admin_auth
      username      = "admin"
      groups       = ["system:masters"]
    },
    {
      rolearn     = local.eks_developers_auth
      username      = "developers"
    },

  ]
  map_accounts = [data.aws_caller_identity.current.account_id]

  node_security_group_additional_rules = {
    # Extend node-to-node security group rules. Recommended and required for the Add-ons
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Recommended outbound traffic for Node groups
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
    # Allows Control Plane Nodes to talk to Worker nodes on all ports. Added this to simplify the example and further avoid issues with Add-ons communication with Control plane.
    # This can be restricted further to specific port based on the requirement for each Add-on e.g., metrics-server 4443, spark-operator 8080, karpenter 8443 etc.
    # Change this according to your security requirements if needed
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }
  
  managed_node_groups = {
#     mg_5 = {
#       node_group_name      = "managed-ondemand"
#       instance_types       = ["m5.large"]
#       # if running with vpc module replace with module.primary_vpc.private_subnets  
#       subnet_ids           = local.eks_subnets # dev
#     }
    mng_lt = {
      # Node Group configuration
      node_group_name = "mng_lt" # Max 40 characters for node group name

      ami_type               = "AL2_x86_64"  # Available options -> AL2_x86_64, AL2_x86_64_GPU, AL2_ARM_64, CUSTOM
      release_version        = ""            # Enter AMI release version to deploy the latest AMI released by AWS. Used only when you specify ami_type
      capacity_type          = "ON_DEMAND"   # ON_DEMAND or SPOT
      instance_types         = ["m5.large"] # List of instances used only for SPOT type
      format_mount_nvme_disk = true          # format and mount NVMe disks ; default to false

      # Launch template configuration
      create_launch_template = true              # false will use the default launch template
      launch_template_os     = "amazonlinux2eks" # amazonlinux2eks or bottlerocket

      enable_monitoring = true
      eni_delete        = true
      public_ip         = false # Use this to enable public IP for EC2 instances; only for public subnets used in launch templates

      http_endpoint               = "enabled"
      http_tokens                 = "optional"
      http_put_response_hop_limit = 3

      # pre_userdata can be used in both cases where you provide custom_ami_id or ami_type
      pre_userdata = <<-EOT
        yum install -y amazon-ssm-agent
        systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        chmod +x kubectl
        pip3 install --upgrade awscli
        aws eks --region ${var.region} update-kubeconfig --name ${local.name}
        mkdir -p /home/ssm-user/.kube
        cp -i /root/.kube/config /home/ssm-user/.kube/config
        chmod +x /home/ssm-user/.kube/config
        sudo chmod -R ugo+rwx /home/ssm-user/.kube/
        echo "changed owner to ssm-user"
      EOT

      # Taints can be applied through EKS API or through Bootstrap script using kubelet_extra_args
      # e.g., k8s_taints = [{key= "spot", value="true", "effect"="NO_SCHEDULE"}]
      k8s_taints = []

      # Node Labels can be applied through EKS API or through Bootstrap script using kubelet_extra_args
      k8s_labels = {
        Environment = var.env
        Zone        = var.env
        Runtime     = "docker"
      }

      # Node Group scaling configuration
      desired_size = 5
      max_size     = 8
      min_size     = 3

      block_device_mappings = [
        {
          device_name = "/dev/xvda"
          volume_type = "gp3"
          volume_size = 50
        }
      ]

      # Node Group network configuration
      subnet_type = "private" # public or private - Default uses the private subnets used in control plane if you don't pass the "subnet_ids"
      subnet_ids  = local.eks_subnets      # Defaults to private subnet-ids used by EKS Control plane. Define your private/public subnets list with comma separated subnet_ids  = ['subnet1','subnet2','subnet3']

      additional_iam_policies = [] # Attach additional IAM policies to the IAM role attached to this worker group

      # SSH ACCESS Optional - Recommended to use SSM Session manager
      remote_access         = false
      ec2_ssh_key           = ""
      ssh_security_group_id = ""

      additional_tags = {
        ExtraTag    = "m5l-on-demand"
        subnet_type = "private"
      }
    }

    mng_custom_ami = {
      # Node Group configuration
      node_group_name = "mng_custom_ami" # Max 40 characters for node group name

      # custom_ami_id is optional when you provide ami_type. Enter the Custom AMI id if you want to use your own custom AMI
      custom_ami_id  = var.ami_id
      capacity_type  = "ON_DEMAND"   # ON_DEMAND or SPOT
      instance_types = ["m5.large"]  # List of instances used only for SPOT type

      # Launch template configuration
      create_launch_template = true              # false will use the default launch template
      launch_template_os     = "amazonlinux2eks" # amazonlinux2eks or bottlerocket

      # pre_userdata will be applied by using custom_ami_id or ami_type
      pre_userdata = <<-EOT
        yum install -y amazon-ssm-agent
        systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
      EOT

      # post_userdata will be applied only by using custom_ami_id
      post_userdata = <<-EOT
        echo "Bootstrap successfully completed! You can further apply config or install to run after bootstrap if needed"
      EOT

      # kubelet_extra_args used only when you pass custom_ami_id;
      # --node-labels is used to apply Kubernetes Labels to Nodes
      # --register-with-taints used to apply taints to Nodes
      # e.g., kubelet_extra_args='--node-labels=WorkerType=SPOT,noderole=spark --register-with-taints=spot=true:NoSchedule --max-pods=58',
      # kubelet_extra_args = "--node-labels=WorkerType=SPOT,noderole=spark --register-with-taints=test=true:NoSchedule --max-pods=20"

      # bootstrap_extra_args used only when you pass custom_ami_id. Allows you to change the Container Runtime for Nodes
      # e.g., bootstrap_extra_args="--use-max-pods false --container-runtime containerd"
      # bootstrap_extra_args = "--use-max-pods false --container-runtime containerd"

      # Taints can be applied through EKS API or through Bootstrap script using kubelet_extra_args
      k8s_taints = []

      # Node Labels can be applied through EKS API or through Bootstrap script using kubelet_extra_args
      k8s_labels = {
        Environment = var.env
        Zone        = var.env
        Runtime     = "docker"
      }

      enable_monitoring = true
      eni_delete        = true
      public_ip         = false # Use this to enable public IP for EC2 instances; only for public subnets used in launch templates

      # Node Group scaling configuration
      desired_size = 2
      max_size     = 2
      min_size     = 2

      block_device_mappings = [
        {
          device_name = "/dev/xvda"
          volume_type = "gp3"
          volume_size = 50
        }
      ]

      # Node Group network configuration
      subnet_type = "private" # public or private - Default uses the private subnets used in control plane if you don't pass the "subnet_ids"
      subnet_ids  = local.eks_subnets        # Defaults to private subnet-ids used by EKS Control plane. Define your private/public subnets list with comma separated subnet_ids  = ['subnet1','subnet2','subnet3']

      additional_iam_policies = [] # Attach additional IAM policies to the IAM role attached to this worker group

      # SSH ACCESS Optional - Recommended to use SSM Session manager
      remote_access         = false
      ec2_ssh_key           = ""
      ssh_security_group_id = ""

      additional_tags = {
        ExtraTag    = "mng-custom-ami"
        Name        = "mng-custom-ami"
        subnet_type = "private"
      }
    }   
  }
  tags = local.tags
}

data "aws_eks_addon_version" "latest" {
  for_each = toset(["vpc-cni", "coredns"])

  addon_name         = each.value
  kubernetes_version = module.eks_blueprints.eks_cluster_version
  most_recent        = true
}

data "aws_eks_addon_version" "default" {
  for_each = toset(["kube-proxy"])

  addon_name         = each.value
  kubernetes_version = module.eks_blueprints.eks_cluster_version
  most_recent        = true
}

module "eks_blueprints_kubernetes_addons" {
  source = "git::https://github.com/ForresterTM/tf-eks.git//modules/kubernetes-addons"
  depends_on = [module.eks_blueprints]
  

  eks_cluster_id               = module.eks_blueprints.eks_cluster_id
  eks_cluster_endpoint         = module.eks_blueprints.eks_cluster_endpoint
  eks_oidc_provider            = module.eks_blueprints.oidc_provider
  eks_cluster_version          = module.eks_blueprints.eks_cluster_version
  eks_worker_security_group_id = module.eks_blueprints.worker_node_security_group_id
  auto_scaling_group_names     = module.eks_blueprints.self_managed_node_group_autoscaling_groups

  # EKS Addons
  enable_amazon_eks_vpc_cni = true
  amazon_eks_vpc_cni_config = {
    addon_version     = data.aws_eks_addon_version.latest["vpc-cni"].version
    resolve_conflicts = "OVERWRITE"
  }

  enable_amazon_eks_coredns = true
  amazon_eks_coredns_config = {
    addon_version     = data.aws_eks_addon_version.latest["coredns"].version
    resolve_conflicts = "OVERWRITE"
  }

  enable_amazon_eks_kube_proxy = true
  amazon_eks_kube_proxy_config = {
    addon_version     = data.aws_eks_addon_version.default["kube-proxy"].version
    resolve_conflicts = "OVERWRITE"
  }

  # Add-ons
  enable_amazon_eks_aws_ebs_csi_driver  = true
  enable_aws_efs_csi_driver             = true
  enable_aws_load_balancer_controller   = true
  enable_cluster_autoscaler             = true
  enable_metrics_server                 = true
  # using cert with ingress controller, and pca
  enable_cert_manager                   = true
  enable_aws_privateca_issuer           = true
  # private ca private.forrester.com (shared from techops account)
  aws_privateca_acmca_arn               = var.certificate_authority
  enable_external_secrets               = true
  enable_aws_cloudwatch_metrics         = true
#   enable_kubernetes_dashboard           = true


  tags = local.tags
}

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = module.eks_blueprints.configure_kubectl
} 
