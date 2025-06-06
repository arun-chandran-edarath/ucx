#!/bin/bash -eE

# The following functions uses Azure logging commands to report test
# details or errors. If the process is not running in Azure environment,
# no special output is generated.

# Logging commands documentation: https://docs.microsoft.com/en-us/azure/devops/pipelines/scripts/logging-commands


RUNNING_IN_AZURE="yes"
if [ -z "$AGENT_ID" ]; then
    RUNNING_IN_AZURE="no"
fi

# Report error and exit
function error() {
    msg=$1
    azure_log_issue "${msg}"
    echo "ERROR: ${msg}"
    exit 1
}

# Define Azure pipeline variable
function azure_set_variable() {
    test "x$RUNNING_IN_AZURE" = "xno" && return
    name=$1
    value=$2
    # Do not remove 'set +x': https://developercommunity.visualstudio.com/t/pipeline-variable-incorrectly-inserts-single-quote/375679#T-N394968
    set +x
    echo "##vso[task.setvariable variable=${name}]${value}"
}

# Report an issue to Azure pipeline and stop step execution
function azure_log_issue() {
    test "x$RUNNING_IN_AZURE" = "xno" && return
    msg=$1
    set +x
    echo "##vso[task.logissue type=error]${msg}"
    echo "##vso[task.complete result=Failed;]"
}

# Report an error message to Azure pipeline
function azure_log_error() {
    test "x$RUNNING_IN_AZURE" = "xno" && return
    msg=$1
    set +x
    echo "##vso[task.logissue type=error]${msg}"
}

# Report an warning message to Azure pipeline
function azure_log_warning() {
    test "x$RUNNING_IN_AZURE" = "xno" && return
    msg=$1
    set +x
    echo "##vso[task.logissue type=warning]${msg}"
}

# Complete the task as "succeeded with issues"
function azure_complete_with_issues() {
    test "x$RUNNING_IN_AZURE" = "xno" && return
    msg=$1
    set +x
    echo "##vso[task.complete result=SucceededWithIssues;]DONE${msg}"
}

# Get IPv4 address of an interface
function get_ip() {
    iface=$1
    ip=$(ip addr show "$iface" | awk '/inet / {print $2}' | awk -F/ '{print $1}')
    echo "$ip"
}

# Get active RDMA interfaces
function get_rdma_interfaces() {
    ibdev2netdev | grep Up | while read line
    do
        ibdev=$(echo "${line}" | awk '{print $1}')
        port=$(echo "${line}" | awk '{print $3}')
        netif=$(echo "${line}" | awk '{print $5}')

        # skip devices that do not have proper gid (representors)
        if ! [ -e "/sys/class/infiniband/${ibdev}/ports/${port}/gids/0" ]
        then
            continue
        fi

        echo ${netif}
    done | sort -u
}

# Prepend each line with a timestamp
function add_timestamp() {
    set +x
    while IFS= read -r line; do
        echo "$(date -u +"%Y-%m-%dT%T.%NZ") $line"
    done
}

function az_init_modules() {
    . /etc/profile.d/modules.sh
    export MODULEPATH="/hpc/local/etc/modulefiles:$MODULEPATH"
    # Read module files (W/A if there're some network instabilities lead to autofs issues)
    find /hpc/local/etc/modulefiles > /dev/null || true
}

#
# Test if an environment module exists and load it if yes.
# Retry 5 times in case of automount failure.
# Otherwise, return error code.
#
function az_module_load() {
    module=$1
    retries=5

    until module avail -t 2>&1 | grep -q "^$module\$"; do
        if [ $retries -gt 1 ]; then
            # Attempt to refresh automount
            echo "Module $module not found, retrying..."
            ls /hpc/local > /dev/null 2>&1
            sleep 1
        else
            # Give up trying
            echo "MODULEPATH='${MODULEPATH}'"
            module avail || true
            ls -l /hpc/local/etc/modulefiles/"$module" || true
            azure_log_warning "Module $module cannot be loaded"
            return 1
        fi
        ((retries--))
    done
    module load $module
    return 0
}

#
# Safe unload for env modules (even if it doesn't exist)
#
function az_module_unload() {
    module=$1
    module unload "${module}" || true
}

# Ensure that GPU is present
check_gpu() {
    name=$1
    if [ "$name" == "gpu" ]; then
        if ! nvidia-smi -L |& grep -q GPU; then
            azure_log_error "No GPU device found on $(hostname -s)"
            exit 1
        fi
        check_nv_peer_mem
    fi
}

check_nv_peer_mem() {
    if [ -f /.dockerenv ]; then
        echo "Skipping nv_peer_mem check on Docker."
        return 0
    fi

    if ! lsmod | grep -q nv_peer_mem; then
        lsmod | grep nv_peer_mem
        systemctl status nv_peer_mem
        azure_log_error "nv_peer_mem module not loaded on $(hostname -s)"
        exit 1
    fi
}

#
# try load cuda modules if nvidia driver is installed
#
try_load_cuda_env() {
    num_gpus=0
    have_cuda=no
    have_gdrcopy=no

    # List relevant modules
    lsmod | grep -P "^(nvidia|nv_peer_mem|gdrdrv)\W" || true

    # Check nvidia driver
    [ -f "/proc/driver/nvidia/version" ] || return 0

    # Check peer mem driver
    [ -f "/sys/kernel/mm/memory_peers/nv_mem/version" ] || return 0

    # Check number of available GPUs
    nvidia-smi -a || true
    num_gpus=$(nvidia-smi -L | grep GPU | wc -l)
    [ "${num_gpus}" -gt 0 ] || return 0

    # Check cuda env module
    az_module_load dev/cuda12.8 || return 0
    have_cuda=yes

    # Check gdrcopy
    if [ -w "/dev/gdrdrv" ]
    then
        az_module_load dev/gdrcopy2.4.4_cuda12.8.0 && have_gdrcopy=yes
    fi
}

load_cuda_env() {
    try_load_cuda_env
    if [ "${have_cuda}" != "yes" ] ; then
        if [ "${ucx_gpu}" = "yes" ] ; then
            azure_log_error "CUDA load failed on GPU node $(hostname -s)"
            exit 1
        fi
        azure_log_warning "Cuda device is not available"
    fi
}

check_release_build() {
    build_reason=$1
    build_sourceversion=$2
    title_mask=$3
    launch=False

    # DRP release scheduled testing
    if [[ $build_reason = "Schedule" && $BUILD_DEFINITIONNAME = *"DRP" ]]
    then
        launch=True

    elif [ "${build_reason}" == "IndividualCI" ] || [ "${build_reason}" == "ResourceTrigger" ]
    then
        if [[ "$BUILD_DEFINITIONNAME" == *"DRP" ]]
        then
            # Release from DRP only if main pipeline is disabled
            launch=$(check_main_pipeline_status)
        else
            launch=True
        fi

    elif [ "${build_reason}" == "PullRequest" ]
    then
        # In case of pull request, HEAD^ is the branch commit we merge with
        range="$(git rev-parse HEAD^)..${build_sourceversion}"
        for sha1 in `git log $range --format="%h"`
        do
            title=`git log -1 --format="%s" $sha1`
            [[ "$title" == "${title_mask}"* ]] && launch=True;
        done
    fi

    echo "##vso[task.setvariable variable=Launch;isOutput=true]${launch}"
}

check_main_pipeline_status() {
    status=$(az pipelines show \
        --name "UCX release" \
        --project "UCX" \
        --organization "https://dev.azure.com/ucfconsort" \
        --query 'queueStatus' \
        -o tsv)

    if [ "$status" == "disabled" ]; then
        echo "True"
    else
        echo "False"
    fi
}

#
# Return arch in the same format as Java System.getProperty("os.arch")
#
get_arch() {
    arch=$(uname -m)
    if [ "$arch" == "x86_64" ]; then
        echo "amd64"
    else
        echo "$arch"
    fi
}

git_clone_with_retry() {
    local branch="$1"
    local target_dir="$2"
    local depth="$3"
    local max_attempts=5

    for attempt in $(seq 1 $max_attempts); do
        echo "Attempt $attempt of $max_attempts: Cloning UCX (branch: $branch)"
        if git clone --depth "$depth" -b "$branch" "$BUILD_REPOSITORY_URI" "$target_dir"; then
            echo "Clone successful"
            return 0
        fi
        echo "Clone failed. Retrying in 5 seconds..."
        sleep 5
    done

    echo "Failed to clone UCX after $max_attempts attempts"
    return 1
}

setup_go_env() {
    go env -w GO111MODULE=auto
}
