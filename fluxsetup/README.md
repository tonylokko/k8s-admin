
# Flux setup
This is the initial configuration files for the flux setup . 
The flux operator is intially installed on cluster initialization and we bootstrap with a this git repo. 

Flux then uses helm and kustomize to take over the base cilium config and also to push any other apps we want.
