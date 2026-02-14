# AWS VPC Lab

Simple Terraform lab that creates one AWS VPC in `eu-central-1`.

## Files

- `main.tf`: AWS provider config and VPC resource
- `.terraform.lock.hcl`: Provider lock file

## Usage

```bash
cd aws-vpc-lab
terraform init
terraform plan
terraform apply
```

## Cleanup

```bash
terraform destroy
```
