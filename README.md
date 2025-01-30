# Reprotest

This script is designed to test the reproducibility of FreeBSD/EC2 AMI
builds, with a goal of catching build reproducibility issues in FreeBSD
before they cause problems during a release cycle.  EC2 AMIs are tested
for the simple reason of convenient availability of resources.

This script is invoked as 

```
sh reprotest.sh -a <AMI Id> -t <Instance type>
```

with optional flags:

```
  -m maxtime         Maximum time in minutes to wait for builds (default 120)
  -o outdir          Directory to place output in (default .)
  -r region          AWS region (default: AWS CLI default)
  -v ebs-volume-size EBS volume size in GB for builds (default: 100)
```

The `-a` option can be passed an AMI Id (ami-xxxxxxxxxxxxxxxxx) or an SSM
Parameter path (resolve:ssm:/aws/service/freebsd/amd64/base/ufs/14.2/STABLE).

I intend to run this weekly as part of the FreeBSD weekly snapshot process.

This code was heavily inspired by https://github.com/5u623l20/repliforge-aws
