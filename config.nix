{ ... }: rec {

  terraform.required_providers.aws.source = "hashicorp/aws";

  provider.aws = {
    region = "us-east-2";
    profile = "home";
  };

  data.aws_ami.nixos = {
    most_recent = true;
    owners = ["080433136561"];

    filter = [
      {
        name = "architecture";
        values = ["x86_64"];
      }
      {
        name = "virtualization-type";
        values = ["hvm"];
      }
    ];
  };

  resource.aws_default_vpc.default.tags.Name = "Default VPC";
  resource.aws_default_subnet.default.availability_zone = "us-east-2c";

  resource.aws_security_group.allow_ssh = {
    name        = "allow_ssh";
    description = "Allow SSH inbound traffic";

    ingress = [
      {
        description      = "TF SSH access";
        from_port        = 22;
        to_port          = 22;
        protocol         = "tcp";
        cidr_blocks      = ["0.0.0.0/0"];
        ipv6_cidr_blocks = ["::/0"];
        prefix_list_ids = [];
        security_groups = [];
        self = false;
      }
    ];

    egress = [
      {
        description      = "TF Allow all egress";
        from_port        = 0;
        to_port          = 0;
        protocol         = "-1";
        cidr_blocks      = ["0.0.0.0/0"];
        ipv6_cidr_blocks = ["::/0"];
        prefix_list_ids = [];
        security_groups = [];
        self = false;
      }
    ];
  };

  resource.aws_key_pair.builder = {
    key_name = "yk";
    public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCogRPMTKyOIQcbS/DqbYijPrreltBHf5ctqFOVAlehvpj8enEE51VSjj4Xs/JEsPWpOJL7Ldp6lDNgFzyuL2AOUWE7wlHx2HrfeCOVkPEzC3uL4OjRTCdsNoleM3Ny2/Qxb0eX2SPoSsEGvpwvTMfUapEa1Ak7Gf39voTYOucoM/lIB/P7MKYkEYiaYaZBcTwjxZa3E+v7At4umSZzv8x24NV60fAyyYmt5hVZRYgoMW+nTU4J/Oq9JGgY7o+WPsOWcgFoSretRnGDwjM1IAUFVpI45rQH2HTKNJ6Bp6ncKwtVaP2dvPdBFe3x2LLEhmh1jDwmbtSXfoVZxbONtub2i/D8DuDhLUNBx/ROgal7N2RgYPcPuNdzfp8hMPjPGZVcSmszC/J1Gz5LqLfWbKKKti4NiSX+euy+aYlgW8zQlUS7aGxzRC/JSgk2KJynFEKJjhj7L9KzsE8ysIgggxYdk18ozDxz2FMPMV5PD1+8x4anWyfda6WR8CXfHlshTwhe+BkgSbsYNe6wZRDGqL2no/PY+GTYRNLgzN721Nv99htIccJoOxeTcs329CppqRNFeDeJkGOnJGc41ze+eVNUkYxOP0O+pNwT7zNDKwRwBnT44F0nNwRByzj2z8i6/deNPmu2sd9IZie8KCygqFiqZ8LjlWTD6JAXPKtTo5GHNQ==";
  };

  resource.aws_spot_instance_request.builder = {
    ami = "\${data.aws_ami.nixos.id}";
    spot_price = "0.17"; # for r5.xlarge
    wait_for_fulfillment = true;
    spot_type = "persistent";
    instance_interruption_behavior = "stop";

    instance_type = "m5.2xlarge";
    key_name = "\${aws_key_pair.builder.key_name}";
    security_groups = [ "\${aws_security_group.allow_ssh.id}" ];
    root_block_device.volume_size = "800";
    subnet_id = "\${aws_default_subnet.default.id}";
    provisioner.local-exec.command = "echo IP address is \${self.public_ip}";
  };

  output.ip.value = "\${aws_spot_instance_request.builder.public_ip}";
}
