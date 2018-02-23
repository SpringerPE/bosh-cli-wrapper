#!/usr/bin/env bash
set -o pipefail  # exit if pipe command fails
[ -z "$DEBUG" ] || set -x

PROGRAM=${PROGRAM:-$(basename "${BASH_SOURCE[0]}")}
PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRAM_LOG="${PROGRAM_LOG:-$(pwd)/$PROGRAM.log}"
PROGRAM_OPTS=$@

BOSH_CLI=${BOSH_CLI:-bosh-cli}
BOSH_EXTRA_OPS="--tty --no-color"

CREDHUB_CLI=${CREDHUB_CLI:-"credhub"}
CREDHUB_USER_NAME=${CREDHUB_USER:-"credhub-cli"}
CREDHUB_USER_SECRET_NAME=${CREDHUB_USER_PASSWORD:-"credhub_cli_password"}

# You can predefine these vars
ENVIRONMENT_PATH='.'
ENVIRONMENT_BOSH_PATH="${PROGRAM%.*}"

ENVIRONMENT_VARS_FILES_DEFAULT=("${ENVIRONMENT_BOSH_PATH}/director-secrets.yml" "${ENVIRONMENT_BOSH_PATH}/director.yml")
ENVIRONMENT_DEPLOYMENTS_PATH="${DEPLOYMENTS_PATH:-${PROGRAM_DIR}/deployments}"
ENVIRONMENT_VARS_FILES=("${ENVIRONMENT_VARS_FILES[@]:-${ENVIRONMENT_VARS_FILES_DEFAULT[@]}}")
ENVIRONMENT_BOSH_STATE="${ENVIRONMENT_BOSH_STATE:-${ENVIRONMENT_BOSH_PATH}/state.json}"
ENVIRONMENT_BOSH_CREDS="${ENVIRONMENT_BOSH_CREDS:-${ENVIRONMENT_BOSH_PATH}/creds.yml}"
ENVIRONMENT_BOSH_OPERATIONS="${ENVIRONMENT_BOSH_OPERATIONS:-${ENVIRONMENT_BOSH_PATH}/operations}"
ENVIRONMENT_BOSH_VARS="${ENVIRONMENT_BOSH_VARS:-${ENVIRONMENT_BOSH_PATH}/variables}"
ENVIRONMENT_BOSH_CLOUD_CONFIG="${ENVIRONMENT_BOSH_CLOUD_CONFIG:-cloud-config}"
ENVIRONMENT_BOSH_RUNTIME_CONFIG="${ENVIRONMENT_BOSH_RUNTIME_CONFIG:-runtime-config}"

BOSH_USER_NAME=${BOSH_USER_NAME:-"bosh_admin"}
BOSH_USER_SECRET_NAME=${BOSH_USER_SECRET_NAME:-"bosh_admin_client_secret"}
BOSH_CA_NAME=${BOSH_CA_NAME:-"default_ca"}
#BOSH_CA_NAME=springer_sbm_ca


###

usage() {
    cat <<EOF
Usage:
    $PROGRAM [options] subcommand [director-folder]

Bosh-client manifest manager. By default it looks for a folder with the same
name as $PROGRAM, so it is possible to deploy other environments directly like
concourse, jumpserver, etc

Options:
    -m      Specify a manifest file, instead of generating a random one
    -p      Deployments path. Default is $DEPLOYMENTS_PATH
    -h      Shows usage help

Subcommands:
    help            Shows usage help
    interpolate     Create the manifest for an environment
    deploy          Update or upgrade environment
    destroy [-f]    Delete environment

Bosh-specific subcommands
    bosh-init            Update or upgrade Bosh Director and apply runtime-config
    bosh-destroy [-f]    Delete Bosh Director
    bosh-env             Show environment variables (It will show secrets!)
    bosh-runtime-config  Apply runtime-config
    bosh-status          Show Bosh status

Also, this script can be sourced to automatically define a set of functions
useful to work with director and it will setup all the environment variables
needed by Bosh client to operate: BOSH_CA_CERT, BOSH_ENVIRONMENT, BOSH_CLIENT, 
BOSH_CLIENT_SECRET.

You can use your BOSH_CLIENT env variables if you set BOSH_USER_NAME to '' (empty).
By default it uses "bosh_admin" user and takes the secret from the vars file.

EOF
}

log() {
    local message=${1}
    local timestamp=`date +%y:%m:%d-%H:%M:%S`
    echo "${timestamp} :: ${message}" >> "${PROGRAM_LOG}"
}

echo_log() {
    local message=${1}
    local timestamp=`date +%y:%m:%d-%H:%M:%S`
    echo "${timestamp} :: ${message}" | tee -a "${PROGRAM_LOG}"
}

# Print a message without \n at the end
echon_log() {
    local message=${1}
    local timestamp=`date +%y:%m:%d-%H:%M:%S`
    echo -n "${timestamp} :: ${message}" | tee -a "${PROGRAM_LOG}"
}

# Print a message and exit with error
die() {
    echo_log "ERROR: $1"
    exit 1
}

# System check
# path=.
bosh_system_check() {
    local path=$1

    if ! [ -x "$(command -v ${BOSH_CLI})" ]; then
        echo_log "Bosh client is not installed. Please download it from https://bosh.io/docs/cli-v2.html"
        return 1
    fi
    if ! ${BOSH_CLI} -v | grep -q "^version *2\."; then
        echo_log "Bosh client version 2 is not installed. Please download it from https://bosh.io/docs/cli-v2.html"
        return 1
    fi
    if ! [ -d "${path}/${ENVIRONMENT_BOSH_OPERATIONS}" ]; then
        echo_log "Bosh Director config folder does not exist, exiting"
        return 1
    fi
    if ! [ -x "$(command -v ${CREDHUB_CLI})" ]; then
        echo_log "Credhub client is not installed. Please download it from https://github.com/cloudfoundry-incubator/credhub-cli"
        return 1
    fi
    return 0
}

# Generate a manifest
bosh_interpolate() {
    local final_manifest_file="${1}"; shift
    local manifest_operations_path="${1}"; shift
    local varfile="${1}"; shift
    local varsfiles=("${@}")

    local bosh_operations=()
    local operations=()
    local rvalue
    local output
    local cmd="${BOSH_CLI} interpolate"

    if [ ! -d ${manifest_operations_path} ]
    then
        echo_log "ERROR Cannot find path ${manifest_operations_path}"
        return 1
    fi
    # Get list of operation files by order in the specific path
    while IFS=  read -r -d $'\0' line
    do
        bosh_operations+=("${line}")
    done < <(find ${manifest_operations_path} -xtype f \( -name "*.yml" -o -name "*.yaml" \) -print0 | sort -z)
    # check if there are files there
    if [ ${#bosh_operations[@]} == 0 ]
    then
        echo_log "No files to interpolate"
        return 10
    fi
    # Get the first operation, it is the manifest base file
    cmd="${cmd} ${bosh_operations[0]}"
    operations=("${bosh_operations[@]:1}")
    cmd="${cmd} ${operations[@]/#/-o }"
    # List of varsfiles with the proper path
    cmd="${cmd} ${varsfiles[@]/#/--vars-file }"
    # Optional varfile
    [ -n "${varfile}" ] && cmd="${cmd} --var-file '${varfile}'"
    echo_log "Interpolating manifest: ${cmd}"
    # Exec process
    output=$(${cmd} > >(tee -a ${PROGRAM_LOG}) 2> >(tee -a ${PROGRAM_LOG} >&2))
    rvalue=$?
    if [ ${rvalue} == 0 ]
    then
        echo "${output}" > "${final_manifest_file}"
        echo_log "Manifest generated at ${final_manifest_file}"
    else
        echo_log "ERROR, Could not generate manifest!"
        echo_log "${output}"
    fi
    return ${rvalue}
}


# List all vars files
bosh_var_files() {
    local path="${1}"

    local vars_path="${path}/${ENVIRONMENT_BOSH_VARS}"
    local varsfiles=()

    if [ -d "${vars_path}" ]
    then
        while IFS=  read -r -d $'\0' line
        do
            varsfiles+=("${line}")
        done < <(find ${vars_path} -xtype f \( -name "*.yml" -o -name "*.yaml" \) -print0 | sort -z)
    fi
    for i in ${ENVIRONMENT_VARS_FILES[@]}
    do
        [ -e "${path}/${i}" ] && varsfiles+=("${path}/${i}")
    done
    for i in ${varsfiles[@]}
    do
        echo "${i}"
    done
}


# create-env, destroy-env interpolate bosh directors environments
# path=.
bosh_environment_manage() {
    local path="${1}"
    local action="${2}"
    local manifest="${3}"

    local rvalue
    local cmd
    local varfile=""
    local state="${path}/${ENVIRONMENT_BOSH_STATE}"
    local secrets="${path}/${ENVIRONMENT_BOSH_CREDS}"
    local operations="${path}/${ENVIRONMENT_BOSH_OPERATIONS}"
    local varsfiles=($(bosh_var_files "${path}"))

    bosh_interpolate "${manifest}" "${operations}" "${varfile}" "${varsfiles[@]}"
    rvalue=$?
    if [ ${rvalue} != 0 ]
    then
        echo_log "ERROR Cannot generate manifest for ${path}"
        return ${rvalue}
    fi
    if [ "${action}" != "interpolate" ]
    then
        # Exec process
        cmd="${BOSH_CLI} ${BOSH_EXTRA_OPS} ${action} ${manifest} --vars-store ${secrets} --state ${state}"
        echo_log "Running ${action}: ${cmd}"
        # Run it!
        ${cmd} > >(tee -a ${PROGRAM_LOG}) 2> >(tee -a ${PROGRAM_LOG} >&2)
        rvalue=$?
    fi
    return ${rvalue}
}


bosh_env() {
    local action="${1:-unset}"     # export, unset, echo

    if [ "${action}" != "echo" ]
    then
        echo_log "Performing ${action} on Bosh env variables"
        if [ -n "${BOSH_USER_NAME}" ]
        then
            ${action} BOSH_CLIENT_SECRET
            ${action} BOSH_CLIENT
        fi
        ${action} BOSH_CA_CERT
        ${action} BOSH_ENVIRONMENT
    else
        if [ -n "${BOSH_USER_NAME}" ]
        then
            echo "export BOSH_CLIENT_SECRET='$BOSH_CLIENT_SECRET'"
            echo "export BOSH_CLIENT='$BOSH_CLIENT'"
        fi
        echo "export BOSH_CA_CERT='$BOSH_CA_CERT'"
        echo "export BOSH_ENVIRONMENT='$BOSH_ENVIRONMENT'"
    fi
}



bosh_search_variable() {
    local path="${1}"
    local key="${2}"

    local variable
    local rvalue=1

    for f in $(bosh_var_files "${path}")
    do
        variable=$(${BOSH_CLI} int "${f}" --path=${key} 2>/dev/null)
        rvalue=$?
        if [ ${rvalue} == 0 ]
        then
          echo "${f}"
          echo "${variable}"
          rvalue=0
          break
        fi
    done
    return ${rvalue}
}



# Define the environment variables to operate with the Director. The ones for bosh_env
# path=.
bosh_set_env() {
    local path="${1}"

    local secrets="${path}/${ENVIRONMENT_BOSH_CREDS}"
    local rvalue
    local bosh_client
    local bosh_client_secret
    local bosh_ca_cert
    local bosh_environment
    local ca=0

    bosh_env unset

    echo_log "Defining Bosh env variables ..."
    # Client
    if [ -n "${BOSH_USER_NAME}" ]
    then
        bosh_client="${BOSH_USER_NAME}"
        bosh_client_secret=$(${BOSH_CLI} int "${secrets}" --path="/${BOSH_USER_SECRET_NAME}" 2>/dev/null)
        rvalue=$?
        if [ ${rvalue} == 0 ]
        then
            BOSH_CLIENT="${bosh_client}"
            BOSH_CLIENT_SECRET="${bosh_client_secret}"
            echo_log "BOSH_CLIENT=${BOSH_CLIENT}"
            echo_log "BOSH_CLIENT_SECRET=\$(${BOSH_CLI} int "${secrets}" --path=/${BOSH_USER_SECRET_NAME})"
        else
            echo_log "No Bosh user client environment variables defined!"
        fi
    fi
    # CA cert
    bosh_ca_cert=$(${BOSH_CLI} int "${secrets}" --path=/${BOSH_CA_NAME}/ca 2>/dev/null)
    rvalue=$?
    if [ ${rvalue} != 0 ]
    then
        bosh_ca_cert=$(bosh_search_variable "${path}" "/${BOSH_CA_NAME}/ca")
        rvalue=$?
        if [ ${rvalue} == 0 ]
        then
            BOSH_CA_CERT=$(echo "${bosh_ca_cert}" | tail -n +2)
            echo_log "BOSH_CA_CERT=\$(${BOSH_CLI} int $(echo "${bosh_ca_cert}" | head -n 1) --path=/${BOSH_CA_NAME}/ca"
            ca=1
        fi
    else
        BOSH_CA_CERT="${bosh_ca_cert}"
        echo_log "BOSH_CA_CERT=\$(${BOSH_CLI} int "${secrets}" --path=/${BOSH_CA_NAME}/ca)"
        ca=1
    fi
    [ ${ca} == 0 ] && echo_log "No Bosh Director CA Cert defined!"
    bosh_environment=$(bosh_search_variable "${path}" "/director_name")
    bosh_director=$(echo "${bosh_environment}" | tail -n +2)
    if ping -c 1 "${bosh_director}" > /dev/null 2>&1
    then
        BOSH_ENVIRONMENT="${bosh_director}"
        echo_log "BOSH_ENVIRONMENT=\$(${BOSH_CLI} int $(echo "${bosh_environment}" | head -n 1) --path=/director_name)"
    else
        bosh_environment=$(bosh_search_variable "${path}" "/internal_ip")
        BOSH_ENVIRONMENT=$(echo "${bosh_environment}" | tail -n +2)
        echo_log "BOSH_ENVIRONMENT=\$(${BOSH_CLI} int $(echo "${bosh_environment}" | head -n 1) --path=/internal_ip)"
    fi
    echo_log "Targeting BOSH_ENVIRONMENT=${BOSH_ENVIRONMENT}"
    bosh_env export
}


# path=.
bosh_set_credhub() {
    local path="${1}"

    local director_name
    local credhub_api_url
    local rvalue

    bosh_set_env "${path}"

    echo_log "Getting Credhub settings from Bosh"
    director_name=$(bosh_director_name)
    rvalue=$?
    if [ ${rvalue} != 0 ] || [ -z "${director_name}" ]
    then
        echo_log "ERROR, Cannot get BOSH Director Name! Please make sure you have bosh properly set."
        return 1
    fi
    if [ -z "${BOSH_ENVIRONMENT}" ]
    then
        credhub_host=$(${BOSH_CLI} int "${path}/director.yml" --path=/internal_ip)
        if [ ${rvalue} != 0 ]
        then
            echo_log "ERROR, Cannot determine Credhub API!, please define BOSH_ENVIRONMENT to a proper dns name or IP"
            return ${rvalue}
        fi
    else
        credhub_host="${BOSH_ENVIRONMENT}"
    fi
    credhub_api_url="https://${credhub_host}:8844"
    credhub_set "${path}" "${credhub_api_url}" "${CREDHUB_USER_NAME}" "${CREDHUB_USER_SECRET_NAME}"
    rvalue=$?
    return ${rvalue}
}


# Define environment variables to operate with
# path=.
credhub_set() {
    local path="${1}"
    local credhub_api_url="${2}"
    local credhub_user="${3}"
    local credhub_user_password_path="${4}"

    local secrets="${path}/${ENVIRONMENT_BOSH_CREDS}"
    local credhub_user_password
    local credhub_host
    local tmp_uaa_ca_file
    local tmp_credhub_ca_file

    echo_log "Credhub API: ${credhub_api_url}"
    # UAA TLS
    echo_log "Getting UAA TLS CA: ${BOSH_CLI} int '${secrets}' --path='/uaa_ssl/ca' > ${tmp_uaa_ca_file}"
    tmp_uaa_ca_file="$(mktemp)"
    ${BOSH_CLI} int "${secrets}" --path=/uaa_ssl/ca > "${tmp_uaa_ca_file}"
    rvalue=$?
    if [ ${rvalue} != 0 ]
    then
        echo_log "ERROR, Cannot get key '/uaa_sl/ca' in '${secrets}'"
        return ${rvalue}
    fi
    # Credhub TLS
    echo_log "Getting Credhub TLS CA: ${BOSH_CLI} int '${secrets}' --path='/credhub_tls/ca' > ${tmp_credhub_ca_file}"
    tmp_credhub_ca_file="$(mktemp)"
    ${BOSH_CLI} int "${secrets}" --path=/credhub_tls/ca > "${tmp_credhub_ca_file}"
    rvalue=$?
    if [ ${rvalue} != 0 ]
    then
        echo_log "ERROR, Cannot get key '/credhub_tls/ca' in '${secrets}'"
        return ${rvalue}
    fi
    echo_log "Credhub user/password '${credhub_user}': ${BOSH_CLI} int '${secrets}' --path='/${credhub_user_password_path}'"
    credhub_user_password=$(${BOSH_CLI} int "${secrets}" --path="/${credhub_user_password_path}" 2>/dev/null)
    rvalue=$?
    if [ ${rvalue} != 0 ]
    then
        echo_log "Cannot get key '${credhub_user_password_path}' in '${secrets}'"
        return ${rvalue}
    fi
    echo_log "RUN: ${CREDHUB_CLI} login -u ${credhub_user} -p ****** -s '${credhub_api_url}' --ca-cert '${tmp_credhub_ca_file}' --ca-cert '${tmp_uaa_ca_file}'"
    ${CREDHUB_CLI} login -u credhub-cli -p "${credhub_user_password}" -s "${credhub_api_url}" --ca-cert "${tmp_credhub_ca_file}" --ca-cert "${tmp_uaa_ca_file}" > /dev/null
    rvalue=$?
    [ ${rvalue} != 0 ] && echo_log "ERROR, cannot login in ${credhub_api_url} with the defined settings"
    return ${rvalue}
}


bosh_show_status() {
    echo_log "Showing the status of the targeting director. Running: ${BOSH_CLI} environment"
    ${BOSH_CLI} environment
    rvalue=$?
    [ ${rvalue} != 0 ] && echo_log "ERROR, cannot query Bosh director!"
    return ${rvalue}
}


bosh_uuid() {
    ${BOSH_CLI} --tty --no-color environment | awk '/^UUID/{ print $2 }'
}


bosh_director_name() {
    ${BOSH_CLI} --tty --no-color environment | awk '/^Name/{ print $2 }'
}


bosh_cpi_platform() {
    ${BOSH_CLI} --tty --no-color environment | awk '/^CPI/{ split($2,a,"_"); print a[1] }'
}


# path=.
bosh_update_runtime_config() {
    local path="${1}"
    local runtime_config_file="${2}"

    local rvalue
    local runc_path="${path}/${ENVIRONMENT_BOSH_RUNTIME_CONFIG}"

    if [ ! -d "${runc_path}" ]
    then
        echo_log "No runtime-config folder!"
        return 0
    fi
    [ -z "${runtime_config_file}" ] && runtime_config_file="$(mktemp)"
    echo_log "Generating and applying runtime-config manifest ..."
    bosh_interpolate "${runtime_config_file}" "${runc_path}"
    rvalue=$?
    if [ ${rvalue} == 10 ]
    then
        echo_log "Skipping runtime-config!"
        return 0
    elif [ ${rvalue} != 0 ]
    then
        echo_log "ERROR, Could not deploy to Bosh Director!"
        return ${rvalue}
    fi
    echo_log "Applying runtime config, running: ${BOSH_CLI} update-runtime-config -n ${runtime_config_file}"
    ${BOSH_CLI} update-runtime-config -n "${runtime_config_file}" > >(tee -a ${PROGRAM_LOG}) 2> >(tee -a ${PROGRAM_LOG} >&2)
    rvalue=$?
    if [ ${rvalue} != 0 ]
    then
        echo_log "ERROR, Could not apply runtime-config!"
    fi
    return ${rvalue}
}


# path=.
bosh_update_cloud_config() {
    local path="${1}"
    local cloud_config_file="${2}"

    local rvalue
    local cc_path="${path}/${ENVIRONMENT_BOSH_CLOUD_CONFIG}"

    if [ ! -d "${cc_path}" ]
    then
        echo_log "No cloud-config folder!"
        return 0
    fi
    [ -z "${cloud_config_file}" ] && cloud_config_file="$(mktemp)"
    echo_log "Generating and applying cloud-config manifest ..."
    bosh_interpolate "${cloud_config_file}" "${cc_path}"
    rvalue=$?
    if [ ${rvalue} == 10 ]
    then
        echo_log "Skipping cloud-config!"
        return 0
    elif [ ${rvalue} != 0 ]
    then
        echo_log "ERROR, Could not deploy to Bosh Director!"
        return ${rvalue}
    fi
    echo_log "Applying cloud config, running: ${BOSH_CLI} update-cloud-config -n ${cloud_config_file}"
    ${BOSH_CLI} update-cloud-config -n "${cloud_config_file}" > >(tee -a ${PROGRAM_LOG}) 2> >(tee -a ${PROGRAM_LOG} >&2)
    rvalue=$?
    if [ ${rvalue} != 0 ]
    then
        echo_log "ERROR, Could not apply cloud-config!"
    fi
    return ${rvalue}
}


bosh_deploy_manifest() {
    local deployment="${1}"
    local manifest="${2}"

    echo_log "Deploying '${manifest}' to Bosh Director in ${deployment} ..."
    echo_log "RUN: ${BOSH_CLI} -d "${deployment}" -n deploy "${manifest}" --no-redact"
    ${BOSH_CLI} -d "${deployment}" -n deploy "${manifest}" --no-redact > >(tee -a ${PROGRAM_LOG}) 2> >(tee -a ${PROGRAM_LOG} >&2)
    rvalue=$?
    if [ ${rvalue} == 0 ]
    then
        echo_log "OK, deployment updated"
    else
        echo_log "ERROR, Could not deploy to Bosh Director!"
    fi
    return ${rvalue}
}


bosh_upload_stemcell() {
    local cpi="${1}"
    local version="${2}"
    local os=${3:-"ubuntu-trusty"}

    local rvalue
    local stemcell

    echo_log "Uploading ${os} version ${version} for ${cpi} to Bosh Director ..."
    case $2 in
    "gcp")
        stemcell="https://s3.amazonaws.com/bosh-core-stemcells/google/bosh-stemcell-${version}-google-kvm-${os}-go_agent.tgz"
        ;;
    "vsphere")
        stemcell="https://s3.amazonaws.com/bosh-core-stemcells/vsphere/bosh-stemcell-${version}-vsphere-esxi-${os}-go_agent.tgz"
        ;;
    "openstack")
        stemcell="https://s3.amazonaws.com/bosh-core-stemcells/openstack/bosh-stemcell-${version}-openstack-kvm-${os}-go_agent.tgz"
        ;;
     "aws")
        stemcell="https://s3.amazonaws.com/bosh-aws-light-stemcells/light-bosh-stemcell-${version}-aws-xen-hvm-${os}-go_agent.tgz"
      ;;
    esac
    echo_log "RUN: ${BOSH_CLI} upload-stemcell ${stemcell}"
    ${BOSH_CLI} upload-stemcell "${stemcell}" > >(tee -a ${PROGRAM_LOG}) 2> >(tee -a ${PROGRAM_LOG} >&2)
    rvalue=$?
    if [ ${rvalue} == 0 ]
    then
        echo_log "OK, Stemcell uploaded"
    else
        echo_log "ERROR, Could not upload stemcell to Bosh Director!"
    fi
    return ${rvalue}
}


bosh_upload_release() {
    local release="${1}"

    echo_log "Uploading ${release} to Bosh Director ..."
    echo_log "RUN: ${BOSH_CLI} upload-release ${release}"
    ${BOSH_CLI} upload-release "${release}" > >(tee -a ${PROGRAM_LOG}) 2> >(tee -a ${PROGRAM_LOG} >&2)
    rvalue=$?
    if [ ${rvalue} == 0 ]
    then
        echo_log "OK, Release uploaded to Bosh Director"
    else
        echo_log "ERROR, Could not upload release to Bosh Director!"
    fi
    return ${rvalue}
}


bosh_finish() {
    local rvalue=$?
    local files=("${@}")

    for f in "${files[@]}"
    do
        echo_log "Deleting temp file ${f}"
        rm -f "${f}"
    done
    echo_log "EXIT rc=${rvalue}"
    exit ${rvalue}
}



################################################################################

# Program
if [ "$0" == "${BASH_SOURCE[0]}" ]
then
    DELETE_MANIFEST=1
    ENVIRONMENT_FOLDER="${ENVIRONMENT_PATH}"
    MANIFEST="$(mktemp)"
    ACTION=""
    RVALUE=0
    STDOUT=0
    FORCE=0
    echo_log "Running '$0 $*' logging to '${PROGRAM_LOG}'"
    # Parse main options
    while getopts ":hp:m:" opt
    do
        case ${opt} in
            h)
                usage
                exit 0
                ;;
            p)
                ENVIRONMENT_FOLDER="${OPTARG}"
                ;;
            m)
                if [ "${OPTARG}" != "-" ]
                then
                    MANIFEST="${OPTARG}"
                    DELETE_MANIFEST=0
                else
                    STDOUT=1
                fi
                ;;
            :)
                die "Option -${OPTARG} requires an argument"
                ;;
        esac
    done
    shift $((OPTIND -1))
    SUBCOMMAND=$1
    shift  # Remove 'subcommand' from the argument list
    bosh_system_check "${ENVIRONMENT_FOLDER}"
    if [ $? != 0 ]
    then
        usage
        die "Please fix your system to continue"
    fi
    if [ ${DELETE_MANIFEST} == 1 ]
    then
        trap "bosh_finish ${MANIFEST}" SIGINT SIGTERM SIGKILL
    else
        trap "bosh_finish" SIGINT SIGTERM SIGKILL
    fi
    OPTIND=0
    case "${SUBCOMMAND}" in
        # Parse options to each sub command
        help)
            usage
            exit 0
            ;;
        deploy)
            bosh_environment_manage "${ENVIRONMENT_FOLDER}" create-env "${MANIFEST}"
            RVALUE=$?
            ;;
        interpolate)
            bosh_environment_manage "${ENVIRONMENT_FOLDER}" interpolate "${MANIFEST}"
            RVALUE=$?
            [ ${STDOUT} == 1 ] && cat "${MANIFEST}"
            ;;
        destroy|bosh-destroy)
            # Process force option
            while getopts ":f" optsub
            do
                case ${optsub} in
                    f)
                        FORCE=1
                        ;;
                    \?)
                        die "Invalid Option: -$OPTARG"
                        ;;
                esac
            done
            shift $((OPTIND -1))
            if [ ${FORCE} == 1 ]
            then
                bosh_environment_manage "${ENVIRONMENT_FOLDER}" delete-env "${MANIFEST}"
                RVALUE=$?
            else
                echo_log "Destroy an environment requires a bit more force"
            fi
            ;;
        bosh-init)
            bosh_environment_manage "${ENVIRONMENT_FOLDER}" create-env "${MANIFEST}"
            RVALUE=$?
            if [ $RVALUE == 0 ]
            then
                bosh_set_env "${ENVIRONMENT_FOLDER}"
                bosh_update_runtime_config "${ENVIRONMENT_FOLDER}"
                RVALUE=$?
                [ $RVALUE == 0 ] && bosh_show_status
            fi
            ;;
        bosh-runtime-config)
            bosh_set_env "${ENVIRONMENT_FOLDER}"
            bosh_update_runtime_config "${ENVIRONMENT_FOLDER}" "${MANIFEST}"
            RVALUE=$?
            ;;
        bosh-env)
            bosh_set_env "${ENVIRONMENT_FOLDER}"
            bosh_env "echo"
            RVALUE=$?
            ;;
        bosh-status)
            bosh_set_env "${ENVIRONMENT_FOLDER}"
            bosh_show_status
            RVALUE=$?
            ;;
        *)
            usage
            die "Invalid or no subcommand: ${SUBCOMMAND}"
            ;;
    esac
    [ ${DELETE_MANIFEST} == 1 ] && rm -f ${MANIFEST}
    if [ ${RVALUE} == 0 ]
    then
       echo_log "DONE: ${RVALUE}"
    else
       echo_log "ERROR: ${RVALUE}"
    fi
    exit ${RVALUE}
else
    bosh_system_check "${ENVIRONMENT_PATH}"
fi

