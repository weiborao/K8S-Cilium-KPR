# K8S-Cilium-KPR
The automation codes to install and setup K8S and Cilium.

1. Automated VM Setup: Describes how to use automated scripts (created with Gemini) to install three Ubuntu 24.04 virtual machines, including create-vms.sh, user-data, network-config, and meta-data examples.
2. Kubernetes Installation with Ansible: Explains how to use Ansible to automate the Kubernetes installation process, including script content and execution procedures.
3. Local DNS and BGP Configuration: Details setting up a local DNS server using dnsmasq and configuring FRR BGP, all managed via Ansible scripts.
4. Kubernetes Cluster and Cilium Installation: This core section covers initializing the Kubernetes cluster with kubeadm, installing Helm using Ansible, and then deploying Cilium and Hubble UI via Helm. It also touches on installing the enterprise Cilium-cli and configuring Cilium BGP.
5. Application Deployment and Testing: Demonstrates deploying a Star Wars demo application provided by Isovalent and how to capture network packets (Pod to Pod, Pod to External) and visualize network flows using Hubble UI.
6. Automation of K8S and Cilium Installation: Discusses steps to fully automate the entire installation process, including setting up passwordless SSH login between Kubernetes nodes.
7. Common Kubectl Commands: Provides a list of frequently used kubectl commands for managing the cluster.

Detail tutorial please refer to:
https://weiborao.link/K8S-Cilium-Replace-kube-proxy.html
