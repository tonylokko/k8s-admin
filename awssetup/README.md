# AWS Setup

We're going to setup a basic system with 1 master , 2 workers.

There's a few parts to this. 

# VPC setup (Network)

Initially setup a dedicated vpc for the cluster in my aws account. 
This should have an internet gateway. The nodes themselves will live in a private subnet. 
There will be a nat gateway for egress traffic also. 
The security policies for aws should be set to allow traffic between nodes. 

# EC2 Setup

There will be 3 vms created in ec2 that will attach to our vpcs. The k8s master needs a minimum of 2 vcpu and 4gb of ram. 
There are a few defaults that need to be set per host , things like swapoff , bridging etc we can use the cloud-init config to customize this. 
Since we' re already customizing on the host on setup we may as well install the rest there too. Containerd can be installed on power up as well as the k8s configu and etcd etc. 
The initial bootstrap token and certificates can be retrieved from the awscli and stored in certmanager to give us a little extra security. 





