# AWS k3s Deployment Capstone

Real infrastructure, provisioned and managed end to end: Terraform provisions an AWS EC2 instance, k3s runs a real Kubernetes cluster on it, and the real monitoring-lab app runs on that cluster, reachable from the public internet. The goal is a full CI/CD path from code push to running service. Built as the capstone project combining everything from the earlier Kubernetes fundamentals, Terraform fundamentals, and CI/CD pipeline work.

This project is in progress. This document reflects what is actually built and working so far, not the finished state.

## Status

- Phase 1 (Terraform provisions EC2, security group, Elastic IP): done
- Phase 2 (k3s installed and reachable from a local machine): done
- Phase 3 (deploy the real app to the cluster): done
- Phase 4 (GitHub Actions automation): pending
- Phase 5 (final documentation): pending

## Why k3s instead of EKS

AWS's managed Kubernetes service, EKS, charges roughly $0.10/hour for the control plane alone, continuously, regardless of workload size, around $72/month if left running. That cost is not justified for a small, single-node portfolio project.

k3s is a lightweight, fully compliant Kubernetes distribution that runs its own control plane on a plain EC2 instance. The only cost is the EC2 instance itself, and a small instance size is covered under AWS's free tier for the first 12 months.

The tradeoff, stated honestly: this project does not demonstrate AWS-managed high availability, patching, or control-plane scaling, since those are exactly what EKS would have handled. What it does demonstrate is a full understanding of what a managed control plane is actually doing under the hood, since this project runs and administers one directly.

## Architecture

Terraform provisions:
- One EC2 instance (t3.micro, free tier eligible)
- A security group, opening only the ports actually needed: SSH (22) and the Kubernetes API (6443), both restricted to a specific IP; the app's NodePort (30080) and HTTP (80), open publicly since they're meant to be reachable
- An Elastic IP, so the instance's public address stays stable across restarts

k3s runs directly on that instance as a systemd service, providing a real, single-node Kubernetes cluster, with Traefik, ServiceLB, and metrics-server deliberately disabled to fit the instance's memory budget.

The app itself is built from the same Dockerfile as the earlier CI/CD pipeline project, pushed to a public Docker Hub repository, and deployed to the cluster as a Kubernetes Deployment and a NodePort Service, exposing it directly on port 30080.

## Real issues encountered, and how they were diagnosed

### IAM permissions were too narrow for EC2 provisioning

The IAM user driving Terraform was originally scoped to `AmazonS3FullAccess` only, from earlier testing with an S3 bucket. The first `terraform plan` against this project failed with a clear `403 UnauthorizedOperation` error on `ec2:DescribeImages`. This was expected behavior, not a bug, the least-privilege setup was correctly blocking an action it hadn't been granted. Fixed by attaching `AmazonEC2FullAccess` to the same user, extending permissions deliberately as the project's actual needs grew, rather than granting broad access upfront.

### k3s became unstable under memory pressure

After installing k3s, `kubectl get nodes` hung and eventually failed with a TLS handshake timeout. Checking `sudo journalctl -u k3s` showed repeated `Slow SQL`, `context deadline exceeded`, and `all Nodes are not-Ready` messages from the internal etcd-compatible database. Checking `free -h` showed the instance's 1GB of RAM (`t3.micro`) was almost fully consumed, with zero swap configured as a buffer.

Root cause: k3s installs several components by default, Traefik (ingress controller), ServiceLB (load balancer support), and metrics-server, none of which this project needs, and together they were enough to exhaust the available memory.

Fix: disabled the unused components via a k3s config file (`disable: [traefik, servicelb, metrics-server]`), and added a 1GB swap file as a safety buffer against future memory spikes. Resolved cleanly with no cost, confirmed by a clean `kubectl get nodes` response afterward. A `t3.small` upgrade was identified as a fallback if this hadn't been sufficient, but wasn't needed.

### TLS certificate didn't cover the public Elastic IP

After fixing memory, connecting from a local machine (via the Elastic IP) failed with an `x509: certificate is valid for ... not <public-ip>` error. k3s generates its TLS certificate at first startup, covering only the addresses it can see at that moment: localhost, its internal cluster IP, and the EC2 instance's private AWS-internal IP. It has no way of knowing about a separately NAT-mapped Elastic IP unless told explicitly.

Fixed by adding a `tls-san` entry for the Elastic IP in the k3s config, removing the cached certificate file (`/var/lib/rancher/k3s/server/tls/dynamic-cert.json`) so it would regenerate on restart, then restarting the service. Confirmed by a clean, trusted connection from the local machine afterward.

### kubeconfig file permissions and context management

The k3s-generated kubeconfig at `/etc/rancher/k3s/k3s.yaml` is root-only on the server, by design, since it holds full cluster admin credentials. Copying it directly with `scp` failed with a permission error. Fixed by copying it to a temporary, `ubuntu`-owned location on the server first, pulling that copy instead, then deleting the temporary copy.

Once on the local machine, the file's `server:` address needed to be changed from `127.0.0.1` to the real public IP. Rather than keeping this as a separate file requiring a manually exported `KUBECONFIG` variable every session, it was merged into the default `~/.kube/config` using `kubectl config view --flatten`, giving it its own named context alongside any other clusters, switchable with `kubectl config use-context`.

### A stale security group rule blocked all access after a home IP change

After working correctly in an earlier session, both `kubectl apply` and a direct SSH attempt started hanging indefinitely with `i/o timeout` errors, on two entirely separate ports (22 and 6443). Since both services failed identically, and timeouts (rather than explicit rejections) are how AWS security groups behave when traffic doesn't match any rule, this pointed at the network layer rather than either service itself. Checking the current public IP (`curl https://checkip.amazonaws.com`) confirmed it had changed since the security group rules were written, a common occurrence on home internet connections. Fixed by updating the security group's IP-restricted rules in `main.tf` to the new address and reapplying with Terraform.

### Image built on Apple Silicon failed to run on the x86_64 server

The app's Pod crashed immediately with `exec format error` in its logs. This is a well known signature of a CPU architecture mismatch: the Docker image had been built on an Apple Silicon Mac, defaulting to the `arm64` architecture, but the EC2 instance runs on standard `x86_64` hardware, unable to execute an `arm64` binary at all. Fixed by rebuilding the image explicitly with `docker build --platform linux/amd64`, pushing the corrected image, and deleting the broken Pod so the Deployment would pull the new one. Noted as a required setting to carry into the Phase 4 GitHub Actions workflow as well, even though GitHub's runners are `x86_64` by default and wouldn't hit this specific issue, it's worth setting explicitly rather than relying on coincidence.

## Running it

Provision the infrastructure:

    terraform init
    terraform apply

Get the instance's public IP:

    terraform output instance_public_ip

SSH in:

    ssh -i ~/.ssh/capstone-key ubuntu@<ip>

Switch kubectl to the capstone cluster (once the context has been set up locally):

    kubectl config use-context default
    kubectl get nodes

Build and push the app image (from the monitoring-lab app folder), explicitly for the server's architecture:

    docker build --platform linux/amd64 -t mayffi/monitoring-lab-app:latest .
    docker push mayffi/monitoring-lab-app:latest

Deploy the app to the cluster:

    cd k8s
    kubectl apply -f deployment.yaml
    kubectl apply -f service.yaml
    kubectl get pods

Check the app is reachable:

    curl http://<ip>:30080/health

Tear down when not actively in use, since this project runs a real, continuously-billed-against-free-tier EC2 instance:

    terraform destroy