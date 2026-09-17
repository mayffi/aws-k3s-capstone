output "instance_public_ip" {
  value = aws_eip.capstone_eip.public_ip
}
