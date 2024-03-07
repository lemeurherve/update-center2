#!/bin/bash -ex

# Used later for rsyncing updates
UPDATES_SITE="updates.jenkins.io"
RSYNC_USER="www-data"
if [[ -z "${ROOT_FOLDER}" ]]; then
    ROOT_FOLDER="/home/jenkins/lemeurherve/pr-745" # TODO: remove after debug, tmp folder where we copied the content from updates.jenkins.io
fi

# For syncing R2 buckets aws-cli is configured through environment variables (from Jenkins credentials)
# https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html
export AWS_DEFAULT_REGION='auto'

## Install jq, required by generate.sh script
wget --no-verbose -O jq https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 || { echo "Failed to download jq" >&2 ; exit 1; }
chmod +x jq || { echo 'Failed to make jq executable' >&2 ; exit 1; }

export PATH=.:$PATH

## Generate the content of 'www2' and 'download' folders
# "$( dirname "$0" )/generate.sh" www2 download

# push plugins to mirrors.jenkins-ci.org
# chmod -R a+r download
# rsync -avz --size-only download/plugins/ ${RSYNC_USER}@${UPDATES_SITE}:/srv/releases/jenkins/plugins

# # Invoke a minimal mirrorsync to mirrorbits which will use the 'recent-releases.json' file as input
# ssh ${RSYNC_USER}@${UPDATES_SITE} "cat > /tmp/update-center2-rerecent-releases.json" < www2/experimental/recent-releases.json
# ssh ${RSYNC_USER}@${UPDATES_SITE} "/srv/releases/sync-recent-releases.sh /tmp/update-center2-rerecent-releases.json"

# # push generated index to the production servers
# # 'updates' come from tool installer generator, so leave that alone, but otherwise
# # delete old sites
chmod -R a+r "${ROOT_FOLDER}/www2"

## Commented out: original rsync command to PKG VM (should be in the parallelized step below)
# rsync -acvz www2/ --exclude=/updates --delete ${RSYNC_USER}@${UPDATES_SITE}:/var/www/${UPDATES_SITE}

function parallelfunction() {
    echo "=== parallelfunction: $1"

    case $1 in
    rsync*)
        # Push generated index to the production server **tmp folder**
        time rsync --archive --checksum --verbose --compress \
            --exclude=/updates `# populated by https://github.com/jenkins-infra/crawler` \
            --delete `# delete old sites` \
            --stats `# add verbose statistics` \
            "${ROOT_FOLDER}/www2/" "${RSYNC_USER}@${UPDATES_SITE}:/tmp/lemeurherve/pr-745/www/${UPDATES_SITE}"
            # in the real script: ./www2/ ${RSYNC_USER}@${UPDATES_SITE}:/var/www/${UPDATES_SITE}
        ;;

    azsync*)
        # Retrieve a signed File Share URL and put it in $FILESHARE_SIGNED_URL
        ls -al
        # shellcheck source=/dev/null
        fileShareSignedUrl=$(source ./site/get-fileshare-signed-url.sh)
        # Sync Azure File Share content using www3 to avoid symlinks
        time azcopy sync "${ROOT_FOLDER}/www3/" "${fileShareSignedUrl}" \
            --recursive=true \
            --exclude-path="updates" `# populated by https://github.com/jenkins-infra/crawler` \
            --delete-destination=true
        ;;

    s3sync*)
        # Retrieve the R2 bucket and the R2 endpoint from the task name passed as argument, minus "s3sync" prefix
        updates_r2_bucket_and_endpoint="${1#s3sync}"
        r2_bucket=${updates_r2_bucket_and_endpoint%|*}
        r2_endpoint=${updates_r2_bucket_and_endpoint#*|}

        # Sync CloudFlare R2 buckets content excluding 'updates' folder from www3 sync (without symlinks)
        # as this folder is populated by https://github.com/jenkins-infra/crawler/blob/master/Jenkinsfile
        time aws s3 sync "${ROOT_FOLDER}/www3/" "s3://${r2_bucket}/" \
            --no-progress \
            --no-follow-symlinks \
            --size-only \
            --exclude '.htaccess' \
            --endpoint-url "${r2_endpoint}"
        ;;

    *)
        echo -n 'Warning: unknown parameter'
        ;;
    esac

}

## need to export variables used within the functions above
export UPDATES_SITE
export RSYNC_USER
export ROOT_FOLDER

## export function to use with parallel
export -f parallelfunction

## parallel added within the permanent trusted agent here:
# https://github.com/jenkins-infra/jenkins-infra/blob/production/dist/profile/manifests/buildagent.pp
command -v parallel >/dev/null 2>&1 || { echo 'ERROR: parralel command not found. Exiting.'; exit 1; }

# Sync only updates.jenkins.io tmp folder by default
tasks=('rsync')

# Sync updates.jenkins.io and azure.updates.jenkins.io File Share and R2 bucket(s) if the flag is set
if [[ ${OPT_IN_SYNC_FS_R2} == 'optin' ]]
then
    # TIME sync, used by mirrorbits to know the last update date to take in account
    date +%s > "${ROOT_FOLDER}"/www2/TIME

    # Perform a copy with dereference symlink (object storage do not support symlinks)
    rm -rf ./www3/ # Cleanup

    ## No need to remove the symlinks as the `azcopy sync` for symlinks is not yet supported and we use `--no-follow-symlinks` for `aws s3 sync`
    rsync --archive --verbose \
                --copy-links `# derefence symlinks` \
                --safe-links `# ignore symlinks outside of copied tree` \
                --exclude='updates' `# Exclude ALL 'updates' directories, not only the root /updates (because symlink dereferencing create additional directories` \
                "${ROOT_FOLDER}/www2/" "${ROOT_FOLDER}/www3/"
                # in the real script: ./www2/ ./www3/

    # Add File Share sync to the tasks
    tasks+=('azsync')

    # Add each R2 bucket sync to the tasks
    updates_r2_bucket_and_endpoint_pairs=("westeurope-updates-jenkins-io|https://8d1838a43923148c5cee18ccc356a594.r2.cloudflarestorage.com")
    for r2_bucket_and_endpoint_pair in "${updates_r2_bucket_and_endpoint_pairs[@]}"
    do
        tasks+=("s3sync${r2_bucket_and_endpoint_pair}")
    done
fi

echo '----------------------- Launch synchronisation(s) -----------------------'
parallel --halt-on-error now,fail=1 parallelfunction ::: "${tasks[@]}"

# Wait for all deferred tasks
echo '============================ all done ============================'

# Trigger a mirror scan on mirrorbits if the flag is set
if [[ ${OPT_IN_SYNC_FS_R2} == 'optin' ]]
then
    echo '== Triggering a mirror scan on mirrorbits...'
    # Kubernetes namespace of mirrorbits
    mirrorbits_namespace='updates-jenkins-io'

    # Requires a valid kubernetes credential file at $KUBECONFIG or $HOME/.kube/config by default
    pod_name=$(kubectl --namespace="${mirrorbits_namespace}" --no-headers=true get pod --output=name | grep mirrorbits | head -n1)
    kubectl --namespace="${mirrorbits_namespace}" --container=mirrorbits-lite exec "${pod_name}" -- mirrorbits scan -all -enable -timeout=120
fi
