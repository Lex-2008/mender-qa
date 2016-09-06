#!/bin/false

# This file should be sourced, not run.

# When sourced, this script will do several things:
#
# 1. Will wait for the cloud-init service to finish running, in order to enforce
#    serial execution of initialization steps. It will post the output when
#    finished, if any.
#
# 2. If $HOME/proxy-target.txt exists, it means this is a proxy host, and the
#    real build machine is on the host specified by the login details inside
#    that file. If the file does not exist, we are on the build slave itself.
#    After figuring that stuff out, this script will run either on_proxy() or
#    on_slave(), depending on which of those is true (both must be defined prior
#    to sourcing this script). Any remaining script commands before this script
#    was sourced are also run, but only on the slave, not on the proxy. Note
#    that commands that were executed *before* this script was sourced will run
#    on both hosts, so make sure this is sourced early.
#
# The script is expected to be sourced early in the init-script phase after
# provisioning.

# Make sure error detection and verbose output is on, if they aren't already.
set -x -e

while pgrep cloud-init >/dev/null 2>&1
do
    # Wait until the cloud-init stage is done.
    sleep 10
done

cat /var/log/cloud-init-output.log || true

if [ -f $HOME/proxy-target.txt ]
then
    ret=0
    on_proxy || ret=$?
    # Failure to find a function returns 127, so check for that specifically,
    # otherwise there was an error inside the function.
    if [ $ret -ne 0 -a $ret -ne 127 ]
    then
        exit $ret
    fi

    login="$(cat $HOME/proxy-target.txt)"
    # Put our currently executing script on the proxy target.
    rsync -cze "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" "$0" $login:commands.sh
    # And the important parts of the environment.
    for var in \
        BUILD_CAUSE \
        BUILD_CAUSE_UPSTREAMTRIGGER \
        BUILD_DISPLAY_NAME \
        BUILD_ID \
        BUILD_NUMBER \
        BUILD_TAG \
        BUILD_URL \
        EXECUTOR_NUMBER \
        HUDSON_COOKIE \
        HUDSON_HOME \
        HUDSON_SERVER_COOKIE \
        HUDSON_URL \
        JENKINS_HOME \
        JENKINS_SERVER_COOKIE \
        JENKINS_URL \
        JOB_BASE_NAME \
        JOB_NAME \
        JOB_URL \
        LOGNAME \
        NODE_LABELS \
        NODE_NAME \
        ROOT_BUILD_CAUSE \
        ROOT_BUILD_CAUSE_MANUALTRIGGER \
        WORKSPACE \
        label
    do
        eval "echo $var=\\\"\$$var\\\""
        echo "export $var"
    done > env.sh
    rsync -cze "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" env.sh $login:.
    # And the helper tools, including this script.
    rsync --delete -czrlpe "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" $HOME/mender-qa $login:.
    # Copy the workspace. If there is no workspace defined, we are not in the
    # job section yet.
    if [ -n "$WORKSPACE" ]
    then
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no $login mkdir -p "$WORKSPACE"
        rsync --delete -czrlpe "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" "$WORKSPACE"/ $login:"$WORKSPACE"/
    fi

    # Run the actual job.
    ret=0
    ssh -o BatchMode=yes -o StrictHostKeyChecking=no $login ". env.sh && cd $WORKSPACE && $HOME/commands.sh" "$@" || ret=$?

    # Copy the workspace back after job has ended.
    if [ -n "$WORKSPACE" ]
    then
        rsync --delete -czrlpe "ssh -o BatchMode=yes -o StrictHostKeyChecking=no" $login:"$WORKSPACE"/ "$WORKSPACE"/
    fi
    # Return the error code from the job.
    exit $ret
else
    ret=0
    on_slave || ret=$?
    # Failure to find a function returns 127, so check for that specifically,
    # otherwise there was an error inside the function.
    if [ $ret -ne 0 -a $ret -ne 127 ]
    then
        exit $ret
    fi
    # Else continue.
fi