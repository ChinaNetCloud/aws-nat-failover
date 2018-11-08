# NAT failover script for AWS

It works by using ping from secondary NAT instance 
to check availability of primary instance. If ping 
fails it will initiate failover via API calls. 
Failover includes moving EIP from primary to 
secondary and replacing default route in routing 
tables to point to secondary instance.

Optionally it can run provided command after 
failover, which can be used for example for 
restoring iptables.

## Install

Can be installed by cloning this repo and then doing

```bash
$ chmod +x nat-failover.sh
```

Also you will need to install dependencies:

```bash
$ sudo yum install jq
$ pip install awscli --upgrade
```

or for Debian based systems:

```bash
$ sudo apt install jq
$ pip install awscli --upgrade
```

## Configure

This script can be run with crond or any task scheduler
of your choice at desired frequency.
The script takes following configuration parameters 
which can be edited in-script or provided as 
environment variables:

1. **NEIGHBOR_ID** (required) - is an instance ID of other instance
2. **RT_IDS** (required) - a space separated list of routing 
   tables IDs that require changing default route on failover
3. **EIP_ID** (required) - NAT assigned EIP allocation ID
4. **POST_FAILOVER_CMD** (optional) - a shell command that will be 
   executed after failover. Note -- it is a command and not path
   to script file. If you want to execute script, you will have to
   provide main executable, i.e. "/bin/sh /path/to/script.sh"

For security reasons it is recommended to use IAM role on NAT 
instance to allow them to call API instead of storing API keys 
on server. To further restrict what these servers can or cannot do
below is minimal IAM policy that should be attached to IAM Role
linked to these NAT instances:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "VisualEditor0",
            "Effect": "Allow",
            "Action": [
                "ec2:StopInstances"
            ],
            "Resource": [
                "arn:aws-cn:ec2:AWS_REGION:ACCOUNT_ID:instance/INSTANCE_ID",
                "arn:aws-cn:ec2:AWS_REGION:ACCOUNT_ID:instance/INSTANCE_ID"
            ]
        },
        {
            "Sid": "VisualEditor1",
            "Effect": "Allow",
            "Action": [
                "ec2:ReplaceRoute"
            ],
            "Resource": [
                "arn:aws-cn:ec2:AWS_REGION:ACCOUNT_ID:route-table/ROUTING_TABLE_ID",
                "arn:aws-cn:ec2:AWS_REGION:ACCOUNT_ID:route-table/ROUTING_TABLE_ID"
            ]
        },
        {
            "Sid": "VisualEditor2",
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeAddresses",
                "ec2:DescribeInstances",
                "ec2:DescribeNetworkInterfaces",
                "ec2:AssociateAddress",
                "ec2:DescribeRouteTables"
            ],
            "Resource": "*"
        }
    ]
}
```



## Example

It is not recommended to run it too frequently to prevent it from 
concurrent running. I would suggest to run with minimum 5 minute 
interval:

```text
*/5 * * * * NEIGHBOR_ID=i-XXX RT_IDS="rtb-XXX rtb-YYY" EIP_ID=eipalloc-ZZZ POST_FAILOVER_CMD="" /bin/sh /path/to/script/nat-failover.sh >> /var/log/nat-failover.out.log 2>> /var/log/nat-failover.err.log
```

The above example is going to write default log to 
`/var/log/nat-failover.out.log`, and it will write 
something there ONLY in the event when failover is 
triggered.

Script errors in above example (such as failed API 
calls, missing arguments etc) are written to 
`/var/log/nat-failover.err.log`.

## License

MIT License (see LICENSE file)
