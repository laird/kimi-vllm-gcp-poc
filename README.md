# Kimi K2.5 on GCP (vLLM POC)

Proof-of-concept for running [Kimi K2.5](https://huggingface.co/moonshotai/Kimi-K2.5) (Moonshot AI) on Google Cloud with vLLM, Terraform, and start/stop scripts. The goal is an OpenAI-compatible API on a 4× NVIDIA H100 box that you can start for a session and stop so you are not billed for idle GPUs.

This repository has no project files at the root. The working package lives here:

`docs/Kimi_2-5_GCP_POC_Setup/kimi-k25-gcp-deployment/`

A nearly identical copy of the same package is in [laird/kimi-k2-5-poc](https://github.com/laird/kimi-k2-5-poc). Use one of the two repos, not both.

## What you need

1. A GCP project with billing enabled
2. Approved GPU quota for H100 in your region ([quota docs](https://cloud.google.com/docs/quotas/gpu))
3. The [gcloud CLI](https://cloud.google.com/sdk/docs/install), authenticated to that project
4. [Terraform](https://developer.hashicorp.com/terraform/install) 1.0 or later

Expect on-demand cost around **$16/hour** for 4× H100, or about **$5/hour** on Spot, plus persistent disk (on the order of **$100/month**, not only while the VM is running). Confirm current prices in the GCP calculator before you apply.

## Install and deploy

```bash
git clone https://github.com/laird/kimi-vllm-gcp-poc.git
cd kimi-vllm-gcp-poc/docs/Kimi_2-5_GCP_POC_Setup/kimi-k25-gcp-deployment

export PROJECT_ID=your-gcp-project-id
export ZONE=us-central1-a
export INSTANCE_NAME=kimi-k25-poc

gcloud auth login
gcloud config set project "$PROJECT_ID"

cd terraform
cp terraform.tfvars.example terraform.tfvars   # if the example file is present
# Edit terraform.tfvars (or pass -var) with your project_id, zone, and instance_name
terraform init
terraform plan
terraform apply
cd ..

chmod +x scripts/*.sh
./scripts/start-poc.sh "$PROJECT_ID" "$ZONE" "$INSTANCE_NAME"
```

## First request

```bash
# Use the external IP printed by the start script
curl http://<EXTERNAL_IP>:8000/v1/models

curl http://<EXTERNAL_IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "moonshotai/Kimi-K2.5",
    "messages": [{"role": "user", "content": "Hello, who are you?"}]
  }'
```

Stop the VM when you are done so compute billing stops:

```bash
./scripts/stop-poc.sh "$PROJECT_ID" "$ZONE" "$INSTANCE_NAME"
```

To tear everything down, including disks:

```bash
cd terraform && terraform destroy
```

## More detail

The nested [package README](docs/Kimi_2-5_GCP_POC_Setup/kimi-k25-gcp-deployment/README.md) covers status checks, logs, firewall notes, and cleanup options. There is also a Word guide in `docs/Kimi_2-5_GCP_POC_Setup/`.

## License

The deployment scripts are provided as-is. Comply with [Moonshot AI's model license](https://huggingface.co/moonshotai/Kimi-K2.5) and Google Cloud terms of service. This repo does not yet include a `LICENSE` file for the scripts themselves.
