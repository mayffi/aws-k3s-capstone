# AWS k3s Deployment Capstone

This project started as a way to actually understand what happens underneath managed cloud platforms, instead of just using them. Provisioned a real AWS server with Terraform, installed and ran Kubernetes on it using k3s, and deployed monitoring-lab app to it. Then built a GitHub Actions pipeline that automatically builds, pushes, and deploys the app every time push a change. This pulls together everything I learned across the earlier Kubernetes and Terraform fundamentals work and the CI/CD pipeline project, and it's genuinely the project I understand most deeply out of everything I've built so far, mostly because of how much went wrong along the way and had to be debugged.

## Status

- Phase 1 (Terraform provisions EC2, security group, Elastic IP): done
- Phase 2 (k3s installed and reachable from a local machine): done
- Phase 3 (deploy the real app to the cluster): done
- Phase 4 (GitHub Actions automation): done, proven end to end
- Phase 5 (final documentation): this document

## Why k3s instead of EKS

AWS's managed Kubernetes service, EKS, charges roughly $0.10/hour for the control plane alone, continuously, regardless of workload size, around $72/month if left running. That cost is not justified for a small, single-node portfolio project.

k3s is a lightweight, fully compliant Kubernetes distribution that runs its own control plane on a plain EC2 instance. The only cost is the EC2 instance itself, and a small instance size is covered under AWS's free tier for the first 12 months.

The tradeoff, stated honestly: this project does not demonstrate AWS-managed high availability, patching, or control-plane scaling, since those are exactly what EKS would have handled. What it does demonstrate is a full understanding of what a managed control plane is actually doing under the hood, since this project runs and administers one directly.

## Why a self-hosted GitHub Actions runner, instead of opening a port

Getting GitHub Actions to reach the cluster to trigger a deployment required deciding how the CI pipeline would connect to a server that otherwise only accepts traffic from one known IP. Two straightforward options existed: open SSH to the public internet, or open the Kubernetes API (6443) to the public internet, since GitHub's hosted runners use a huge, constantly changing pool of IPs with no small range to scope a rule to.

Both options would have widened the exact attack surface this project had deliberately kept narrow through every earlier phase. Instead, a self-hosted GitHub Actions runner was installed directly on the EC2 instance. The runner makes its own outbound connection to GitHub to poll for work which already permitted by the existing egress rule. No new inbound port was opened at all; SSH and the Kubernetes API remain exactly as restricted as they were after Phase 1.

The build step itself (`docker build`, memory-hungry) still runs on GitHub's own hosted infrastructure, not the self-hosted runner. Only the lightweight deploy step, a single `kubectl rollout restart`, runs locally on the EC2 instance. This split was deliberate: it keeps the heaviest work off the constrained server entirely.

## Architecture

Terraform provisions:
- One EC2 instance (t3.micro, free tier eligible)
- A security group, opening only the ports actually needed: SSH (22) and the Kubernetes API (6443), both restricted to a specific IP; the app's NodePort (30080) and HTTP (80), open publicly
- An Elastic IP, so the instance's public address stays stable across restarts

k3s runs directly on that instance as a systemd service, with Traefik, ServiceLB, and metrics-server deliberately disabled to fit the instance's memory budget.

The app is built from the same Dockerfile as the earlier CI/CD pipeline project (copied into this repo under `app/` to keep the capstone self-contained), pushed to a public Docker Hub repository, and deployed as a Kubernetes Deployment and NodePort Service on port 30080.

A self-hosted GitHub Actions runner, installed as a systemd service on the EC2 instance, handles deployment. The pipeline (`.github/workflows/deploy.yml`) has two jobs: `build-and-push` runs on GitHub's hosted infrastructure and builds and pushes the image; `deploy` runs on the self-hosted runner and restarts the Kubernetes Deployment, which pulls the freshly pushed image.

## Real issues encountered, and how they were diagnosed

### IAM permissions were too narrow for EC2 provisioning

The IAM user driving Terraform was originally scoped to `AmazonS3FullAccess` only. The first `terraform plan` against this project failed with a `403 UnauthorizedOperation` on `ec2:DescribeImages`, expected behavior from a correctly least-privileged setup, not a bug. Fixed by attaching `AmazonEC2FullAccess`, extending permissions deliberately as the project's actual needs grew.

### k3s became unstable under memory pressure

`kubectl get nodes` hung and failed with a TLS handshake timeout. `sudo journalctl -u k3s` showed repeated `Slow SQL` and `context deadline exceeded` messages from the internal database; `free -h` showed the 1GB `t3.micro` almost fully consumed, with no swap configured. Root cause: k3s's default components, Traefik, ServiceLB, and metrics-server, none needed here, were exhausting available memory. Fixed by disabling them via a k3s config file and adding a 1GB swap file as a buffer, confirmed by a clean `kubectl get nodes` response afterward.

### TLS certificate didn't cover the public Elastic IP

Connecting from a local machine failed with an `x509: certificate is valid for ... not <public-ip>` error. k3s generates its TLS certificate at startup, covering only addresses it can see at that moment, not a separately NAT-mapped Elastic IP. Fixed by adding a `tls-san` entry for the Elastic IP, removing the cached certificate so it would regenerate, and restarting the service.

### kubeconfig file permissions and context management

The k3s-generated kubeconfig at `/etc/rancher/k3s/k3s.yaml` is root-only by design. Copying it directly with `scp` failed with a permission error; fixed by copying it to a temporary, `ubuntu`-owned location on the server first. Locally, rather than requiring a manually exported `KUBECONFIG` every session, it was merged into the default `~/.kube/config` with `kubectl config view --flatten`, giving it its own named context.

### A stale security group rule blocked all access after a home IP change

`kubectl apply` and a direct SSH attempt both started hanging with `i/o timeout` errors on two separate ports. Since both failed identically, and timeouts (not explicit rejections) are how AWS security groups behave against non-matching traffic, this pointed at the network layer. `curl https://checkip.amazonaws.com` confirmed the home IP had changed since the rules were written. Fixed by updating the security group's IP-restricted rules in `main.tf` and reapplying.

### Image built on Apple Silicon failed to run on the x86_64 server

The app's Pod crashed immediately with `exec format error`, the signature of a CPU architecture mismatch: the image had been built on an Apple Silicon Mac (`arm64` by default), but the EC2 instance runs `x86_64`. Fixed by rebuilding explicitly with `docker build --platform linux/amd64`, then deleting the broken Pod so the Deployment would pull the corrected image. This setting was carried into the GitHub Actions build step as well, so the pipeline doesn't depend on GitHub's runners happening to already be x86_64.

### kubectl on the server is a symlink to k3s itself, with its own hardcoded config path

Standard `kubectl` reads `~/.kube/config` by default; k3s's installer instead symlinks `/usr/local/bin/kubectl` to the `k3s` binary, which ignores that convention and hardcodes `/etc/rancher/k3s/k3s.yaml`, root-only, instead. This meant a working copy at `~/.kube/config` still failed until `KUBECONFIG` was set explicitly. For the self-hosted runner specifically, since systemd services don't read `.bashrc` or other interactive shell config, this was set permanently via a `.env` file in the runner's own folder, the runner's documented mechanism for injecting environment variables into the service.

### Self-hosted runner memory footprint, verified rather than assumed

General guidance for GitHub Actions self-hosted runners recommends 2GB RAM minimum, more than this project's entire `t3.micro`. Rather than assuming this would be a problem, or assuming it wouldn't, memory was checked at each stage: before installing the runner, after extracting it, after registering it as a live idle service, and finally during an actual deploy job. Available memory stayed in a stable 96-268MB range throughout, with no continuous downward trend, evidence that keeping the heavy build step on GitHub's hosted infrastructure and only running a lightweight `kubectl rollout restart` locally was enough to avoid repeating the earlier memory crisis, without needing to upgrade the instance size.

## Running it

Provision the infrastructure:

    terraform init
    terraform apply

Get the instance's public IP:

    terraform output instance_public_ip

SSH in:

    ssh -i ~/.ssh/capstone-key ubuntu@<ip>

Switch kubectl to the capstone cluster locally:

    kubectl config use-context default
    kubectl get nodes

Build and push the app image manually (from the app folder), if testing outside the pipeline:

    docker build --platform linux/amd64 -t mayffi/monitoring-lab-app:latest .
    docker push mayffi/monitoring-lab-app:latest

Deploy the app to the cluster manually:

    cd k8s
    kubectl apply -f deployment.yaml
    kubectl apply -f service.yaml
    kubectl get pods

Normal usage: push a change to main, and the GitHub Actions pipeline builds, pushes, and deploys it automatically. Check progress under the repo's Actions tab.

Check the app is reachable:

    curl http://<ip>:30080/health

Tear down when not actively in use, since this project runs a real, continuously-billed-against-free-tier EC2 instance:

    terraform destroy