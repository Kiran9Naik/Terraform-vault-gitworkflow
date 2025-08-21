variable "aws_region" {
  description = "The AWS region to deploy resources in"
  type        = string
  
}
variable "aws_ami" {
  description = "The AMI ID to use for the EC2 instance"
  type        = string
  
}
variable "aws_instance_type" {
  description = "The type of EC2 instance to create"
  type        = string
  
}