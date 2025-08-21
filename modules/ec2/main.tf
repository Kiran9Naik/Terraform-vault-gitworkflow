resource "aws_instance" "kiran" {
    ami           = var.aws_ami
    instance_type = var.aws_instance_type
    
}