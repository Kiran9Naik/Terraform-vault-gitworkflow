module "kiran_ec2" {
    source = "./modules/ec2"
    
    aws_ami           = var.aws_ami
    aws_instance_type = var.aws_instance_type
    aws_region        = var.aws_region
  
}