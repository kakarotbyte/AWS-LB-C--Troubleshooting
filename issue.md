
  Warning  FailedBuildModel  15s  ingress  Failed build model due to couldn't auto-discover subnets: UnauthorizedOperation: You are not authorized to perform this operation. User: arn:aws:sts::991242130495:assumed-role/terraform-20240306204424394500000001/1709757970023949910 is not authorized to perform: ec2:DescribeSubnets because no identity-based policy allows the ec2:DescribeSubnets action
           status code: 403, request id: 3236c122-4895-42a6-b2e7-1ab1e0955d50
           
  Warning  FailedBuildModel  21s (x14 over 62s)  ingress  Failed build model due to conflicting subnets: [subnet-0938d3583b30c5e51 subnet-0ec6058195a1bf6b7] | [subnet-04bfe1b855a325db7 subnet-0a0d7ad676bb6626e]