#!/bin/sh

usage () {
	echo "Usage: $0 -a ami-id -t instance-type [-m maxtime] [-o outdir] [-r region] [-v ebs-volume-size]"
	exit 1
}

cleanup_instance () {
	echo "Terminating instance..."
	"${AWS_BIN}" ec2 terminate-instances --region "${REGION}" --instance-ids "${INST}" >/dev/null
}

cleanup_keypair () {
	echo "Deleting key pair..."
	"${AWS_BIN}" ec2 delete-key-pair --region "${REGION}" --key-name "${WRKDIR}" >/dev/null
	rm ssh.pem ssh.pem.pub
}

cleanup_wrkdir () {
	rm -f user-data
	rmdir "${WRKDIR}"
}

# Parse input
while getopts 'a:m:o:r:t:v:' ch; do
	case "${ch}" in
	a) AMI_ID="${OPTARG}" ;;
	m) MAXTIME="${OPTARG}" ;;
	o) OUTDIR=$(realpath "${OPTARG}") ;;
	r) REGION="${OPTARG}" ;;
	t) ITYPE="${OPTARG}" ;;
	v) ROOT_DISK_SIZE="${OPTARG}" ;;
	esac
done

AWS_BIN=$(command -v aws)

# Check variables
if [ -z "${AWS_BIN}" ]; then
	echo "Cannot find AWS CLI in PATH."
	exit 1
fi

# Set defaults
if [ -z "${REGION}" ]; then
	REGION=$("${AWS_BIN}" configure get region)
fi
if [ -z "${MAXTIME}" ]; then
	MAXTIME=120
fi
if [ -z "${OUTDIR}" ]; then
	OUTDIR=$(pwd)
fi
if [ -z "${ROOT_DISK_SIZE}" ]; then
	ROOT_DISK_SIZE=100
fi

# Check variables
if [ -z "${REGION}" ]; then
	echo "Region must be set in AWS CLI or specified via -r option"
	exit 1
fi
if [ -z "${AMI_ID}" ]; then
	usage
fi
if [ -z "${ITYPE}" ]; then
	usage
fi

# Resolve SSM parameters
case "${AMI_ID}" in
resolve:ssm:*)
	RESOLVED_AMI_ID=$("${AWS_BIN}" ssm get-parameter \
	    --region "${REGION}" --name "${AMI_ID#resolve:ssm:}" \
	    --query "Parameter.Value" --output text)
	if [ -z "${RESOLVED_AMI_ID}" ]; then
		echo "Cannot resolve AMI: ${AMI_ID}"
		exit 1
	fi
	AMI_ID="${RESOLVED_AMI_ID}"
	;;
esac

# Get AMI details from EC2
ROOT_DISK=$("${AWS_BIN}" ec2 describe-images \
    --region "${REGION}" --image-id "${AMI_ID}" \
    --query "Images[0].BlockDeviceMappings[0].Ebs.SnapshotId" --output text)
AMI_NAME=$("${AWS_BIN}" ec2 describe-images \
    --region "${REGION}" --image-id "${AMI_ID}" \
    --query "Images[0].Name" --output text)
AMI_DESC=$("${AWS_BIN}" ec2 describe-images \
    --region "${REGION}" --image-id "${AMI_ID}" \
    --query "Images[0].Description" --output text)

# Parse AMI details
case "${AMI_NAME}" in
*UFS) FS=ufs ;;
*ZFS) FS=zfs ;;
esac
case "${AMI_NAME}" in
*base*) FL=base ;;
*small*) FL=small ;;
*cloud-init*) FL=cloud-init ;;
esac
VERS="${AMI_DESC#* }"
BRANCH="${VERS%@*}"
HASH="${VERS#*@}"
CWTGT=cw-ec2-${FL}-${FS}-raw

# FreeBSD 13 only has base/ufs.
case "${BRANCH}" in
*/13*) FL=base; FS=ufs; CWTGT=cw-ec2 ;;
esac

# Verify that we got details
if [ -z "${ROOT_DISK}" ] || [ -z "${FS}" ] || [ -z "${FL}" ] ||
    [ -z "${BRANCH}" ] || [ -z "${HASH}" ]; then
	echo "Could not extract details for AMI ${AMI_ID} from EC2"
	exit 1
fi

# Create a temporary working directory
WRKDIR=$(mktemp -d -t reprotest) || exit 1
cd "${WRKDIR}"

# Create a configinit script.  The actual work happens in the
# /usr/local/etc/rc.d/reprotest script which is created and runs
# after the instance reboots.
cat <<EOF >user-data
#!/bin/sh
echo 'firstboot_pkgs_list="git-lite sysutils/py-diffoscope sqlite3 xxd"' >> /etc/rc.conf
cat <<EORC >/usr/local/etc/rc.d/reprotest
#!/bin/sh

# PROVIDE: reprotest
# REQUIRE: sshd

. /etc/rc.subr
name="reprotest"
rcvar="reprotest_enable"
start_cmd="reprotest_run"
reprotest_enable=YES

reprotest_run () {
	PATH=$PATH:/usr/local/bin
	AMIDISK=\\\$(realpath /dev/aws/disk/linuxname/sdf)
	JFLAG=-j\\\$(sysctl -n hw.ncpu)
	mkdir /mnt/amiroot
	mount "\\\${AMIDISK}p3" /mnt/amiroot
	git clone --branch ${BRANCH} https://git.freebsd.org/src.git /usr/src
	cd /usr/src && git reset --hard ${HASH}
	make -C /usr/src buildworld buildkernel \\\${JFLAG}
	make -C /usr/src/release WITH_CLOUDWARE=YES ${CWTGT} \\\${JFLAG}
	diffoscope --exclude-directory-metadata yes --html /root/diffoscope.html /mnt/amiroot /usr/obj/usr/src/*/release/${CWTGT}
	touch /root/DONE
}

load_rc_config reprotest
run_rc_command "\\\$1" >> /root/reprotest.log 2>&1
EORC
chmod 755 /usr/local/etc/rc.d/reprotest
touch /firstboot-reboot
EOF

# Create an ssh key pair
echo "Creating and importing a key pair..."
ssh-keygen -q -f ssh.pem -N ""
"${AWS_BIN}" ec2 import-key-pair --region "${REGION}" \
    --key-name "${WRKDIR}" --public-key-material fileb://ssh.pem.pub >/dev/null

# Launch EC2 instance
echo "Launching an ${ITYPE} instance..."
INST=$("${AWS_BIN}" ec2 run-instances --region "${REGION}" \
    --image-id "${AMI_ID}" \
    --key-name "${WRKDIR}" \
    --instance-type "${ITYPE}" \
    --block-device-mappings "
	[
		{
			\"DeviceName\":\"/dev/sda1\",
			\"Ebs\":{
				\"VolumeSize\":$ROOT_DISK_SIZE
			}
		},
		{
			\"DeviceName\":\"/dev/sdf\",
			\"Ebs\":{
				\"SnapshotId\":\"${ROOT_DISK}\"
			}
		}
	]" \
    --user-data fileb://user-data \
    --query "Instances[0].InstanceId" \
    --output text)
if [ -z "${INST}" ]; then
	echo "Failed to launch instance"
	cleanup_keypair
	cleanup_wrkdir
	exit 1
fi

# Get IP address
IP=$("${AWS_BIN}" ec2 describe-instances --region "${REGION}" \
    --instance-id "${INST}" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
if [ -z "${IP}" ]; then
	echo "Failed to get instance IP address"
	cleanup_instance
	cleanup_keypair
	cleanup_wrkdir
	exit 1
fi

# Wait two minutes and get the SSH host key
echo "Waiting for instance to boot..."
sleep 120
echo "Getting SSH host key..."
"${AWS_BIN}" ec2 get-console-output --region "${REGION}" \
    --instance-id "${INST}" \
    --latest \
    --query 'Output' \
    --output text |
    ec2-knownhost "${IP}"

# Wait until done, or up to 120 minutes
echo -n "Waiting for build and diffoscope to complete..."
jot ${MAXTIME} | while read X; do
	if ssh -i ${WRKDIR}/ssh.pem ec2-user@${IP} ls /root/ </dev/null | grep DONE; then
		break
	fi
	echo -n .
	sleep 60
done
echo
scp -i ${WRKDIR}/ssh.pem ec2-user@${IP}:/root/diffoscope.html ${OUTDIR}/
scp -i ${WRKDIR}/ssh.pem ec2-user@${IP}:/root/reprotest.log ${OUTDIR}/

# Clean up
cleanup_instance
cleanup_keypair
cleanup_wrkdir
