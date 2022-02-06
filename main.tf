data "aws_availability_zones" "available" {}
#------------------------------------------------------------------------------
# AWS Virtual Private Network
#------------------------------------------------------------------------------
resource "aws_vpc" "sivakumarvunnam" {
  # The CIDR block for the VPC.
  cidr_block = "17.1.0.0/25"
  # A boolean flag to enable/disable DNS support in the VPC.
  enable_dns_support = true
  # A boolean flag to enable/disable DNS hostnames in the VPC.
  enable_dns_hostnames = true
  tags = {
    Name = "sivakumarvunnam"
  }
}

#------------------------------------------------------------------------------
# AWS Subnets - Public
#------------------------------------------------------------------------------
resource "aws_subnet" "publicsubnet1" {
  vpc_id            = aws_vpc.sivakumarvunnam.id
  cidr_block        = "17.1.0.0/26"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "publicsubnet-${data.aws_availability_zones.available.names[0]}"
  }
}

resource "aws_subnet" "publicsubnet2" {
  vpc_id            = aws_vpc.sivakumarvunnam.id
  cidr_block        = "17.1.0.64/26"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "publicsubnet-${data.aws_availability_zones.available.names[1]}"
  }
}
#------------------------------------------------------------------------------
# AWS Internet Gateway
#------------------------------------------------------------------------------
resource "aws_internet_gateway" "sivakumarvunnam_igw" {
  vpc_id = aws_vpc.sivakumarvunnam.id

  tags = {
    Name = "sivakumarvunnam-InternetGateway"
  }
}
#------------------------------------------------------------------------------
# Public route table
#------------------------------------------------------------------------------
resource "aws_route_table" "sivakumarvunnam_public" {
  vpc_id = aws_vpc.sivakumarvunnam.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sivakumarvunnam_igw.id
  }

  tags = {
    Name = "publicsubnets-routetable-sivakumarvunnam"
  }
}

#------------------------------------------------------------------------------
# Association of Route Table to Subnets
#------------------------------------------------------------------------------
resource "aws_route_table_association" "sivakumarvunnam_us_east_1a_public" {
  subnet_id      = aws_subnet.publicsubnet1.id
  route_table_id = aws_route_table.sivakumarvunnam_public.id
}

resource "aws_route_table_association" "sivakumarvunnam_us_east_1b_public" {
  subnet_id      = aws_subnet.publicsubnet2.id
  route_table_id = aws_route_table.sivakumarvunnam_public.id
}

resource "aws_security_group" "allow_http" {
  name        = "allow_http"
  description = "Allow HTTP inbound connections"
  vpc_id      = aws_vpc.sivakumarvunnam.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Allow HTTP Security Group"
  }
}

data "aws_ami" "amazon-linux-2-ami" {
  most_recent = true

  filter {
    name = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
  }
  owners = ["amazon"]
}
#------------------------------------------------------------------------------
# launch_configuration
#------------------------------------------------------------------------------
resource "aws_launch_configuration" "web" {
  name_prefix = "web-"
  #image_id                    = "ami-0947d2ba12ee1ff75" # Amazon Linux 2 AMI (HVM), SSD Volume Type
  image_id                    = data.aws_ami.amazon-linux-2-ami.id
  instance_type               = "t3a.micro"
  security_groups             = [aws_security_group.allow_http.id]
  associate_public_ip_address = true
  #
  user_data = <<USER_DATA
  #!/bin/bash
  yum update -y
  sudo amazon-linux-extras enable epel
  sudo yum install epel-release
  sudo amazon-linux-extras install nginx1
  echo "$(curl http://169.254.169.254/latest/meta-data/local-ipv4)" > /usr/share/nginx/html/index.html
  chkconfig nginx on
  sudo service nginx restart
    USER_DATA

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "elb_http" {
  name        = "elb_http"
  description = "Allow HTTP traffic to instances through Elastic Load Balancer"
  vpc_id      = aws_vpc.sivakumarvunnam.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Allow HTTP through ELB Security Group"
  }
}

resource "aws_elb" "web_elb" {
  name = "web-elb"
  security_groups = [
    aws_security_group.elb_http.id
  ]
  subnets = [
    aws_subnet.publicsubnet1.id,
    aws_subnet.publicsubnet2.id
  ]

  cross_zone_load_balancing = true

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
    target              = "HTTP:80/"
  }

  listener {
    lb_port           = 80
    lb_protocol       = "http"
    instance_port     = "80"
    instance_protocol = "http"
  }

}
#------------------------------------------------------------------------------
# Autoscaling Group
#------------------------------------------------------------------------------
resource "aws_autoscaling_group" "web" {
  name = "${aws_launch_configuration.web.name}-asg"

  min_size         = 2
  desired_capacity = 2
  max_size         = 5

  health_check_type = "ELB"
  load_balancers = [
    aws_elb.web_elb.id
  ]

  launch_configuration = aws_launch_configuration.web.name

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]

  metrics_granularity = "1Minute"

  vpc_zone_identifier = [
    aws_subnet.publicsubnet1.id,
    aws_subnet.publicsubnet2.id
  ]

  # Required to redeploy without an outage.
  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "web"
    propagate_at_launch = true
  }

}

resource "aws_autoscaling_policy" "web_policy_up" {
  name                   = "web_policy_up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.web.name
}

resource "aws_cloudwatch_metric_alarm" "web_cpu_alarm_up" {
  alarm_name          = "web_cpu_alarm_up"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "60"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }

  alarm_description = "This metric monitor EC2 instance CPU utilization"
  alarm_actions     = [aws_autoscaling_policy.web_policy_up.arn]
}

resource "aws_autoscaling_policy" "web_policy_down" {
  name                   = "web_policy_down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.web.name
}

resource "aws_cloudwatch_metric_alarm" "web_cpu_alarm_down" {
  alarm_name          = "web_cpu_alarm_down"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "120"
  statistic           = "Average"
  threshold           = "10"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }

  alarm_description = "This metric monitor EC2 instance CPU utilization"
  alarm_actions     = [aws_autoscaling_policy.web_policy_down.arn]
}