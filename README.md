#k8s-admin

This repo is a set of scripts and configuration to deploy a simple k8s cluster on aws. 

To get started clone the repo and from the awsetup folder run the deploy.sh script after setting up the appropriate variables in a config.env file. 

#Caveats

The aws setup will deploy a t3.medium ec2 instance and 2 t3.large instances. The cluster setup was tested with version 1.33 of k8s. 
The cluster will deploy flux on the controlplane initially to bootstrap the rest of the cluster. Cilium is deployed as the default cni also. This has an initial deployment at bootstrap time to pull containers and for intial worker communication but afterwards the deployment is managed via flux.

In this case the infastructure is managed via the fluxsetup folder in this repo. 
This will also install amazons ccm and ebs csi. 

#Extra user setup 

Flux also deploys a dev user which has access to the dev namespace. 
The namespace has rbac permissions to allow the user to deploy resources for a deployment. There are example files in the user-deploy folder/ 
There are also 3 scripts which should be run in sequence after cluster initialization to allow an admin to create users kubeconfig for the deployment of those resources. 


